using System.Collections.Specialized;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using ZapretUi.Models;
using ZapretUi.Services;
using MessageBox = System.Windows.MessageBox;
using UserControl = System.Windows.Controls.UserControl;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using TextBox = System.Windows.Controls.TextBox;
using Brush = System.Windows.Media.Brush;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using Visibility = System.Windows.Visibility;

namespace ZapretUi;

public partial class StrategyLabView : UserControl
{
    private StrategyDraft _draft = WinwsArgBuilder.CreateTemplate();
    private CancellationTokenSource? _testCts;
    private bool _rebuilding;

    public Func<Func<Task>, Task>? RunExclusive { get; set; }
    public Func<StrategyInfo?>? GetSelectedStrategy { get; set; }
    public Action? ReloadStrategies { get; set; }
    public Action<CancellationTokenSource>? RegisterTestCts { get; set; }
    public Action<bool>? SetCancelEnabled { get; set; }

    public StrategyLabView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            try
            {
                NameBox.Text = _draft.Name;
                RebuildSections();
                if (SectionList.SelectedIndex < 0)
                    SectionList.SelectedIndex = 0;
                FillOptionList();
                RebuildEditors();
                RefreshPreview();
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.ToString(), "Конструктор");
            }
        };
    }

    private OptionSet CurrentSet
    {
        get
        {
            if (SectionList.SelectedIndex <= 0)
                return _draft.Global;
            var i = SectionList.SelectedIndex - 1;
            if (i >= 0 && i < _draft.Profiles.Count)
                return _draft.Profiles[i].Options;
            return _draft.Global;
        }
    }

    private WinwsOptionScope CurrentScope =>
        SectionList.SelectedIndex <= 0 ? WinwsOptionScope.Global : WinwsOptionScope.Profile;

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _draft.Name = NameBox.Text.Trim();
        RefreshPreview();
    }

    private void RebuildSections()
    {
        var idx = SectionList.SelectedIndex;
        SectionList.Items.Clear();
        SectionList.Items.Add("Глобальные (wf-*)");
        foreach (var p in _draft.Profiles)
            SectionList.Items.Add(p.Title);
        if (idx >= 0 && idx < SectionList.Items.Count)
            SectionList.SelectedIndex = idx;
        else
            SectionList.SelectedIndex = 0;
    }

    private void SectionList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (OptionList == null || EditorsHost == null)
            return;
        FillOptionList();
        RebuildEditors();
    }

    private sealed class OptionPick
    {
        public required string Name { get; init; }
        public required string Display { get; init; }
        public override string ToString() => Display;
    }

    private void OptionFilter_TextChanged(object sender, TextChangedEventArgs e) => FillOptionList();

    private void FillOptionList()
    {
        if (OptionList == null)
            return;
        var scope = CurrentScope;
        var used = new HashSet<string>(CurrentSet.Bindings.Select(b => b.Name), StringComparer.OrdinalIgnoreCase);
        var q = OptionFilter?.Text?.Trim() ?? "";
        var picks = WinwsOptionCatalog.ForScope(scope)
            .Where(opt => opt.Repeatable || !used.Contains(opt.Name))
            .Where(opt => q.Length == 0 ||
                          opt.Name.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                          opt.Group.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                          opt.Help.Contains(q, StringComparison.OrdinalIgnoreCase))
            .OrderBy(o => o.Group)
            .ThenBy(o => o.Name)
            .Select(opt => new OptionPick { Name = opt.Name, Display = $"{opt.Group}  --{opt.Name}" })
            .ToList();
        OptionList.DisplayMemberPath = nameof(OptionPick.Display);
        OptionList.ItemsSource = picks;
        if (picks.Count > 0)
            OptionList.SelectedIndex = 0;
    }

    private void AddProfile_Click(object sender, RoutedEventArgs e)
    {
        _draft.Profiles.Add(new ProfileDraft { Title = $"Профиль {_draft.Profiles.Count + 1}" });
        RebuildSections();
        SectionList.SelectedIndex = _draft.Profiles.Count;
        RefreshPreview();
    }

    private void DupProfile_Click(object sender, RoutedEventArgs e)
    {
        if (SectionList.SelectedIndex <= 0)
            return;
        var src = _draft.Profiles[SectionList.SelectedIndex - 1];
        var copy = new ProfileDraft { Title = src.Title + " копия" };
        foreach (var b in src.Options.Bindings)
        {
            foreach (var v in b.Values)
                copy.Options.AddValue(b.Name, v.Value);
        }
        _draft.Profiles.Add(copy);
        RebuildSections();
        SectionList.SelectedIndex = _draft.Profiles.Count;
        RefreshPreview();
    }

    private void RemoveProfile_Click(object sender, RoutedEventArgs e)
    {
        if (SectionList.SelectedIndex <= 0)
            return;
        if (_draft.Profiles.Count <= 1)
        {
            MessageBox.Show("Нужен хотя бы один профиль.", "Конструктор");
            return;
        }

        _draft.Profiles.RemoveAt(SectionList.SelectedIndex - 1);
        RebuildSections();
        RefreshPreview();
    }

    private void AddOption_Click(object sender, RoutedEventArgs e)
    {
        var name = SelectedOptionName();
        if (string.IsNullOrWhiteSpace(name))
            return;
        var meta = WinwsOptionCatalog.Find(name);
        var existing = CurrentSet.Find(name);
        if (existing != null && meta is { Repeatable: false })
            return;
        var def = DefaultValue(meta);
        CurrentSet.AddValue(name, def);
        FillOptionList();
        RebuildEditors();
        RefreshPreview();
    }

    private string? SelectedOptionName()
    {
        if (OptionList.SelectedItem is OptionPick pick)
            return pick.Name;
        var text = OptionFilter?.Text?.Trim() ?? "";
        if (text.StartsWith("--", StringComparison.Ordinal))
            text = text[2..];
        var sp = text.LastIndexOf("--", StringComparison.Ordinal);
        if (sp >= 0)
            text = text[(sp + 2)..].Trim();
        var fromDisplay = text.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
        if (fromDisplay != null && fromDisplay.StartsWith("--", StringComparison.Ordinal))
            return fromDisplay[2..];
        return text.Length == 0 ? null : text;
    }

    private static string DefaultValue(WinwsOption? meta)
    {
        if (meta == null)
            return "";
        if (meta.Kind == WinwsOptionKind.Flag)
            return "";
        if (meta.Kind == WinwsOptionKind.Int)
            return Math.Max(meta.Min, 1).ToString(CultureInfo.InvariantCulture);
        if (meta.Kind is WinwsOptionKind.Enum or WinwsOptionKind.MultiEnum && meta.Values.Length > 0)
            return meta.Values[0];
        if (meta.Kind == WinwsOptionKind.Ports)
            return "443";
        return meta.DefaultValue;
    }

    private Brush BrushOf(string key) =>
        TryFindResource(key) as Brush ?? new SolidColorBrush(System.Windows.Media.Color.FromRgb(0xE8, 0xEA, 0xF0));

    private void RebuildEditors()
    {
        _rebuilding = true;
        EditorsHost.Children.Clear();
        var set = CurrentSet;
        foreach (var group in set.Bindings.Select(b => WinwsOptionCatalog.Find(b.Name)?.Group ?? "Прочее").Distinct())
        {
            EditorsHost.Children.Add(new TextBlock
            {
                Text = group,
                FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, 8, 0, 6),
                Foreground = BrushOf("Muted")
            });
            var items = set.Bindings
                .Where(b => (WinwsOptionCatalog.Find(b.Name)?.Group ?? "Прочее") == group)
                .ToList();
            var grid = new UniformGrid { Columns = 4 };
            foreach (var binding in items)
                grid.Children.Add(BuildBindingEditor(binding, set));
            EditorsHost.Children.Add(grid);
        }

        _rebuilding = false;
        HookCollection(set);
    }

    private void HookCollection(OptionSet set)
    {
        set.Bindings.CollectionChanged -= BindingsChanged;
        set.Bindings.CollectionChanged += BindingsChanged;
    }

    private void BindingsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (_rebuilding)
            return;
        RefreshPreview();
    }

    private FrameworkElement BuildBindingEditor(OptionBinding binding, OptionSet set)
    {
        var meta = WinwsOptionCatalog.Find(binding.Name);
        var box = new Border
        {
            Background = BrushOf("PanelAlt"),
            BorderBrush = BrushOf("Border"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8),
            Margin = new Thickness(4),
            MinHeight = 96,
            VerticalAlignment = VerticalAlignment.Stretch
        };
        var root = new StackPanel();
        var header = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, 6) };
        var remove = new Button { Content = "×", Width = 32, Margin = new Thickness(8, 0, 0, 0) };
        remove.Click += (_, _) =>
        {
            set.Bindings.Remove(binding);
            FillOptionList();
            RebuildEditors();
            RefreshPreview();
        };
        DockPanel.SetDock(remove, Dock.Right);
        header.Children.Add(remove);
        var title = new TextBlock
        {
            Text = "--" + binding.Name,
            FontWeight = FontWeights.SemiBold,
            ToolTip = meta?.Help ?? ""
        };
        header.Children.Add(title);
        root.Children.Add(header);
        if (!string.IsNullOrWhiteSpace(meta?.Help))
            root.Children.Add(new TextBlock
            {
                Text = meta!.Help,
                Foreground = BrushOf("Muted"),
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 6)
            });

        if (meta?.Kind == WinwsOptionKind.MultiEnum)
        {
            if (binding.Values.Count == 0)
                binding.Values.Add(new OptionValueRow());
            root.Children.Add(BuildMultiEnum(binding.Values[0], meta));
        }
        else
        {
            var valuesHost = new StackPanel();
            void RenderRows()
            {
                valuesHost.Children.Clear();
                if (binding.Values.Count == 0)
                    binding.Values.Add(new OptionValueRow { Value = DefaultValue(meta) });
                for (var i = 0; i < binding.Values.Count; i++)
                {
                    var row = binding.Values[i];
                    var rowDock = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 0, 0, 4) };
                    if (meta?.Repeatable == true)
                    {
                        var del = new Button { Content = "−", Width = 28, Margin = new Thickness(6, 0, 0, 0) };
                        var captured = row;
                        del.Click += (_, _) =>
                        {
                            binding.Values.Remove(captured);
                            if (binding.Values.Count == 0)
                                set.Bindings.Remove(binding);
                            RebuildEditors();
                            RefreshPreview();
                        };
                        DockPanel.SetDock(del, Dock.Right);
                        rowDock.Children.Add(del);
                    }

                    rowDock.Children.Add(BuildValueEditor(row, meta, binding.Name));
                    valuesHost.Children.Add(rowDock);
                }
            }

            RenderRows();
            root.Children.Add(valuesHost);
            if (meta?.Repeatable == true || meta == null)
            {
                var add = new Button
                {
                    Content = "Добавить значение",
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Margin = new Thickness(0, 4, 0, 0)
                };
                add.Click += (_, _) =>
                {
                    binding.Values.Add(new OptionValueRow { Value = DefaultValue(meta) });
                    RebuildEditors();
                    RefreshPreview();
                };
                root.Children.Add(add);
            }
        }

        box.Child = root;
        return box;
    }

    private UIElement BuildMultiEnum(OptionValueRow row, WinwsOption meta)
    {
        var wrap = new WrapPanel();
        var selected = new HashSet<string>(
            (row.Value ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
            StringComparer.OrdinalIgnoreCase);
        foreach (var v in meta.Values)
        {
            var cb = new CheckBox
            {
                Content = v,
                IsChecked = selected.Contains(v),
                Margin = new Thickness(0, 0, 12, 6),
                Foreground = BrushOf("Text")
            };
            cb.Checked += (_, _) => Sync();
            cb.Unchecked += (_, _) => Sync();
            wrap.Children.Add(cb);
        }

        void Sync()
        {
            var vals = wrap.Children.OfType<CheckBox>().Where(c => c.IsChecked == true).Select(c => (string)c.Content);
            row.Value = string.Join(',', vals);
            RefreshPreview();
        }

        return wrap;
    }

    private UIElement BuildValueEditor(OptionValueRow row, WinwsOption? meta, string optionName)
    {
        if (meta?.Kind == WinwsOptionKind.Flag)
        {
            var cb = new CheckBox { Content = "включено", IsChecked = true, Foreground = BrushOf("Text") };
            return cb;
        }

        if (meta?.Kind == WinwsOptionKind.Int)
            return BuildIntEditor(row, meta);

        if (IsCutoff(optionName))
            return BuildCutoffEditor(row);

        if (meta?.Kind == WinwsOptionKind.Enum && meta.Values.Length > 0)
            return BuildPickList(row, meta.Values, freeText: false);

        if (meta?.Kind == WinwsOptionKind.FileBin)
            return BuildPickList(row, BinFiles().ToList(), freeText: true, hint: "файл из bin или ! / 0x…");

        if (meta?.Kind == WinwsOptionKind.FileList)
            return BuildPickList(row, ListFiles().ToList(), freeText: true, hint: "файл из lists");

        return BuildFreeText(row, HintFor(meta));
    }

    private static string HintFor(WinwsOption? meta) => meta?.Kind switch
    {
        WinwsOptionKind.Ports => "порты, напр. 80,443",
        WinwsOptionKind.Tokens => "через запятую, напр. host1,host2",
        WinwsOptionKind.Hex => "напр. 0x00000000",
        _ => "строка-значение для --" + (meta?.Name ?? "opt")
    };

    private UIElement BuildPickList(OptionValueRow row, IReadOnlyList<string> items, bool freeText, string? hint = null)
    {
        var root = new StackPanel();
        TextBox? tb = null;
        if (freeText)
        {
            var editor = (StackPanel)BuildFreeText(row, hint ?? "значение");
            tb = editor.Children.OfType<TextBox>().FirstOrDefault();
            root.Children.Add(editor);
        }

        var combo = new ComboBox
        {
            Margin = new Thickness(0, freeText ? 4 : 0, 0, 0),
            IsEditable = false,
            IsTextSearchEnabled = false,
            ItemsSource = items
        };
        if (!string.IsNullOrEmpty(row.Value) && items.Contains(row.Value))
            combo.SelectedItem = row.Value;
        else if (!freeText && items.Count > 0)
        {
            combo.SelectedIndex = 0;
            row.Value = items[0];
        }

        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is not string s)
                return;
            row.Value = s;
            if (tb != null && tb.Text != s)
                tb.Text = s;
            RefreshPreview();
        };
        root.Children.Add(combo);
        return root;
    }

    private UIElement BuildFreeText(OptionValueRow row, string hint)
    {
        var root = new StackPanel();
        root.Children.Add(new TextBlock
        {
            Text = hint,
            Foreground = BrushOf("Muted"),
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 4)
        });
        var tb = new TextBox
        {
            Text = row.Value ?? "",
            IsReadOnly = false,
            Focusable = true,
            MinHeight = 28
        };
        tb.TextChanged += (_, _) =>
        {
            row.Value = tb.Text;
            RefreshPreview();
        };
        root.Children.Add(tb);
        return root;
    }

    private UIElement BuildIntEditor(OptionValueRow row, WinwsOption meta)
    {
        if (!int.TryParse(row.Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n))
            n = meta.Min;
        n = Math.Clamp(n, meta.Min, meta.Max);
        row.Value = n.ToString(CultureInfo.InvariantCulture);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });
        var slider = new Slider
        {
            Minimum = meta.Min,
            Maximum = meta.Max,
            Value = n,
            TickFrequency = meta.Max > 64 ? 10 : 1,
            IsSnapToTickEnabled = meta.Max <= 64,
            VerticalAlignment = VerticalAlignment.Center
        };
        var box = new TextBox { Text = row.Value, Margin = new Thickness(8, 0, 0, 0) };
        Grid.SetColumn(box, 1);
        slider.ValueChanged += (_, e) =>
        {
            var v = (int)Math.Round(e.NewValue);
            row.Value = v.ToString(CultureInfo.InvariantCulture);
            if (box.Text != row.Value)
                box.Text = row.Value;
            RefreshPreview();
        };
        box.TextChanged += (_, _) =>
        {
            if (int.TryParse(box.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
            {
                parsed = Math.Clamp(parsed, meta.Min, meta.Max);
                row.Value = parsed.ToString(CultureInfo.InvariantCulture);
                if (Math.Abs(slider.Value - parsed) > 0.01)
                    slider.Value = parsed;
            }
            else
                row.Value = box.Text;
            RefreshPreview();
        };
        grid.Children.Add(slider);
        grid.Children.Add(box);
        return grid;
    }

    private UIElement BuildCutoffEditor(OptionValueRow row)
    {
        var m = Regex.Match(row.Value ?? "", @"^([nds])(\d+)$", RegexOptions.IgnoreCase);
        var prefix = m.Success ? m.Groups[1].Value.ToLowerInvariant() : "n";
        var num = m.Success ? int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture) : 3;

        var panel = new DockPanel { LastChildFill = true };
        var kind = new ComboBox { Width = 72, Margin = new Thickness(0, 0, 8, 0) };
        kind.Items.Add("n пакет");
        kind.Items.Add("d data");
        kind.Items.Add("s seq");
        kind.SelectedIndex = prefix == "d" ? 1 : prefix == "s" ? 2 : 0;
        DockPanel.SetDock(kind, Dock.Left);

        var slider = new Slider { Minimum = 1, Maximum = 32, Value = num, IsSnapToTickEnabled = true, TickFrequency = 1, VerticalAlignment = VerticalAlignment.Center };
        void Sync()
        {
            var p = kind.SelectedIndex == 1 ? "d" : kind.SelectedIndex == 2 ? "s" : "n";
            row.Value = p + ((int)slider.Value).ToString(CultureInfo.InvariantCulture);
            RefreshPreview();
        }

        kind.SelectionChanged += (_, _) => Sync();
        slider.ValueChanged += (_, _) => Sync();
        Sync();
        panel.Children.Add(kind);
        panel.Children.Add(slider);
        return panel;
    }

    private static bool IsCutoff(string name) =>
        name.Contains("cutoff", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("dpi-desync-start", StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<string> BinFiles()
    {
        yield return "!";
        yield return "0x00000000";
        if (!Directory.Exists(ZapretPaths.BinDir))
            yield break;
        foreach (var f in Directory.GetFiles(ZapretPaths.BinDir, "*.bin").OrderBy(Path.GetFileName))
            yield return "%BIN%" + Path.GetFileName(f);
    }

    private static IEnumerable<string> ListFiles()
    {
        if (!Directory.Exists(ZapretPaths.ListsDir))
            yield break;
        foreach (var f in Directory.GetFiles(ZapretPaths.ListsDir, "*.txt").OrderBy(Path.GetFileName))
            yield return "%LISTS%" + Path.GetFileName(f);
    }

    private void RefreshPreview()
    {
        if (PreviewBox == null)
            return;
        PreviewBox.Text = WinwsArgBuilder.Build(_draft);
    }

    private void LoadSelected_Click(object sender, RoutedEventArgs e)
    {
        var info = GetSelectedStrategy?.Invoke();
        if (info == null)
        {
            MessageBox.Show("Сначала выберите стратегию на вкладке «Стратегии».", "Конструктор");
            return;
        }

        try
        {
            var raw = StrategyCatalog.ExtractRawCommand(info.BatPath);
            _draft = WinwsArgParser.Parse(raw, info.Name, info.BatPath);
            NameBox.Text = _draft.Name;
            RebuildSections();
            SectionList.SelectedIndex = 0;
            RebuildEditors();
            RefreshPreview();
            LabStatus.Text = "Загружено: " + info.Name;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Конструктор");
        }
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var path = _draft.SourceBatPath;
            var suggested = WinwsBatWriter.SuggestPath(string.IsNullOrWhiteSpace(_draft.Name) ? "custom" : _draft.Name);
            if (string.IsNullOrWhiteSpace(path) || WinwsBatWriter.IsStockPath(path))
            {
                if (!string.IsNullOrWhiteSpace(path) && WinwsBatWriter.IsStockPath(path))
                {
                    var overwrite = MessageBox.Show(
                        $"«{_draft.Name}» — стоковая стратегия. Перезаписать её?\nНет — сохранить как DEV-копию.",
                        "Сохранение",
                        MessageBoxButton.YesNoCancel,
                        MessageBoxImage.Warning);
                    if (overwrite == MessageBoxResult.Cancel)
                        return;
                    if (overwrite == MessageBoxResult.No)
                        path = suggested;
                }
                else
                    path = suggested;
            }

            WinwsBatWriter.Write(_draft, path!);
            NameBox.Text = _draft.Name;
            ReloadStrategies?.Invoke();
            LabStatus.Text = "Сохранено: " + Path.GetFileName(path);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Конструктор");
        }
    }

    private async void TestDraft_Click(object sender, RoutedEventArgs e)
    {
        if (RunExclusive == null)
            return;
        _testCts?.Cancel();
        _testCts = new CancellationTokenSource();
        var ct = _testCts.Token;
        var args = WinwsArgBuilder.BuildResolved(_draft);
        var name = string.IsNullOrWhiteSpace(_draft.Name) ? "draft" : _draft.Name;
        await RunExclusive(async () =>
        {
            RegisterTestCts?.Invoke(_testCts);
            SetCancelEnabled?.Invoke(true);
            LabStatus.Text = "Тест черновика…";
            var targets = StrategyTester.LoadDiscordYouTubeTargets();
            try
            {
                var result = await StrategyTester.TestFromArgumentsAsync(name, args, targets, ct);
                LabStatus.Text = $"Тест: {result.Label}";
            }
            catch (OperationCanceledException)
            {
                LabStatus.Text = "Тест отменён.";
            }
            finally
            {
                SetCancelEnabled?.Invoke(false);
            }
        });
    }
}
