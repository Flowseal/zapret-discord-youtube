namespace ZapretUi.Models;

public enum WinwsOptionScope
{
    Global,
    Profile
}

public enum WinwsOptionKind
{
    Flag,
    Int,
    Enum,
    MultiEnum,
    FileBin,
    FileList,
    Ports,
    String,
    Hex,
    Tokens
}

public sealed class WinwsOption
{
    public required string Name { get; init; }
    public required WinwsOptionScope Scope { get; init; }
    public required WinwsOptionKind Kind { get; init; }
    public required string Group { get; init; }
    public string Help { get; init; } = "";
    public bool Repeatable { get; init; }
    public int Min { get; init; }
    public int Max { get; init; } = 100;
    public string[] Values { get; init; } = [];
    public string DefaultValue { get; init; } = "";
}
