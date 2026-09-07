using System.ComponentModel;
using System.Runtime.CompilerServices;
using ZapretUi.Models;

namespace ZapretUi.Models;

public sealed class StrategyRow : INotifyPropertyChanged
{
    private string _result = "";
    private string _resultKind = "";

    public required StrategyInfo Info { get; init; }
    public string Name => Info.Name;

    public string Result
    {
        get => _result;
        set { _result = value; OnPropertyChanged(); }
    }

    public string ResultKind
    {
        get => _resultKind;
        set { _resultKind = value; OnPropertyChanged(); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
