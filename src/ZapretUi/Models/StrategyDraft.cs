using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace ZapretUi.Models;

public sealed class OptionValueRow : INotifyPropertyChanged
{
    private string _value = "";

    public string Value
    {
        get => _value;
        set
        {
            if (_value == value)
                return;
            _value = value;
            OnPropertyChanged();
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class OptionBinding : INotifyPropertyChanged
{
    public required string Name { get; init; }
    public ObservableCollection<OptionValueRow> Values { get; } = [];

    public void SetSingle(string value)
    {
        if (Values.Count == 0)
            Values.Add(new OptionValueRow { Value = value });
        else
            Values[0].Value = value;
        while (Values.Count > 1)
            Values.RemoveAt(Values.Count - 1);
        OnPropertyChanged(nameof(Values));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class OptionSet
{
    public ObservableCollection<OptionBinding> Bindings { get; } = [];

    public OptionBinding? Find(string name) =>
        Bindings.FirstOrDefault(b => string.Equals(b.Name, name, StringComparison.OrdinalIgnoreCase));

    public OptionBinding GetOrAdd(string name)
    {
        var existing = Find(name);
        if (existing != null)
            return existing;
        var b = new OptionBinding { Name = name };
        Bindings.Add(b);
        return b;
    }

    public void Set(string name, string value)
    {
        var b = GetOrAdd(name);
        b.SetSingle(value);
        if (b.Values.Count == 0)
            b.Values.Add(new OptionValueRow { Value = value });
    }

    public void AddValue(string name, string value)
    {
        var b = GetOrAdd(name);
        b.Values.Add(new OptionValueRow { Value = value });
    }
}

public sealed class ProfileDraft : INotifyPropertyChanged
{
    private string _title = "Профиль";

    public string Title
    {
        get => _title;
        set
        {
            if (_title == value)
                return;
            _title = value;
            OnPropertyChanged();
        }
    }

    public OptionSet Options { get; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class StrategyDraft : INotifyPropertyChanged
{
    private string _name = "custom";

    public string Name
    {
        get => _name;
        set
        {
            if (_name == value)
                return;
            _name = value;
            OnPropertyChanged();
        }
    }

    public string? SourceBatPath { get; set; }

    public OptionSet Global { get; } = new();
    public ObservableCollection<ProfileDraft> Profiles { get; } = [];

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
