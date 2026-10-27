using CrestCore.Application;
using CrestCore.Contracts;

using Xunit;

namespace CrestCore.Tests;

/// Tidy files loose open tabs under new headers and refuses any other tab
/// without changing anything.
public sealed partial class BrowserContractsTests {
    [Fact]
    public void TidyFilesOnlyLooseOpenTabsUnderNewHeaders() {
        var f = new BatchSpace();
        using var device = new TestDevice(f.Session);
        var core = device.Authority;

        device.Send(new TidyCurrentTabs(device.Workspace, f.Space, [new("Reading", [f.Open, f.Last])]));

        var space = core.Current.Spaces[0];
        var tidiedFolder = Assert.Single(space.Folders, folder => folder.Title == "Reading");
        Assert.Same(TabPlacement.Current, tidiedFolder.Location);
        Assert.All(space.Tabs.Where(tab => tab.Id == f.Open || tab.Id == f.Last), tab => Assert.Equal(tidiedFolder.Id, tab.FolderId));

        var tidied = core.Current;
        foreach (var refused in new[] { f.Pinned, f.Saved, f.Left, f.Filed, f.Last })
            Assert.IsType<TabCannotBeTidied>(Assert.Throws<Rejected>(() => device.Send(
                new TidyCurrentTabs(device.Workspace, f.Space, [new("Again", [refused, f.Resident])]))).Rejection);
        Assert.IsType<TidyFolderNeedsTwoTabs>(Assert.Throws<Rejected>(() => device.Send(
            new TidyCurrentTabs(device.Workspace, f.Space, [new("Alone", [f.Resident])]))).Rejection);
        Assert.Same(tidied, core.Current);
    }

    [Fact]
    public void TidyingAgainFilesTabsUnderTheTidyHeaderOfTheSameName() {
        var f = new BatchSpace();
        using var device = new TestDevice(f.Session);
        var core = device.Authority;
        var window = device.Open(f.Space, (f.Space, f.Open));
        device.Send(new TidyCurrentTabs(device.Workspace, f.Space, [new("Reading", [f.Open, f.Last])]));
        var header = Assert.Single(core.Current.Spaces[0].Folders, folder => folder.IsTidyHeader);
        device.Send(new CollapseFolder(device.Workspace, f.Space, header.Id, true));
        Guid[] later = [Guid.NewGuid(), Guid.NewGuid()];
        foreach (var tab in later)
            device.Send(new OpenTab(device.Workspace, window, f.Space, tab, new TabContent("https://example.org/", null, "Later"),
                TabPlacement.Current, null, false));

        device.Send(new TidyCurrentTabs(device.Workspace, f.Space, [new("reading", later)]));

        var space = core.Current.Spaces[0];
        var joined = Assert.Single(space.Folders, folder => folder.IsTidyHeader);
        Assert.Equal((header.Id, "Reading", false), (joined.Id, joined.Title, joined.IsCollapsed));
        Guid[] filed = [.. space.Tabs.Where(tab => tab.FolderId == header.Id).Select(tab => tab.Id)];
        Assert.Equal([f.Open, f.Last], filed[..2]);
        Assert.Equal(later.ToHashSet(), filed[2..].ToHashSet());
    }

    [Fact]
    public void ClosingATidyHeaderArchivesItsTabsAndRemovesIt() {
        var f = new BatchSpace();
        using var device = new TestDevice(f.Session);
        var core = device.Authority;
        var window = device.Open(f.Space, (f.Space, f.Open));
        device.Send(new TidyCurrentTabs(device.Workspace, f.Space, [new("Reading", [f.Open, f.Last])]));
        var header = Assert.Single(core.Current.Spaces[0].Folders, folder => folder.IsTidyHeader);
        Assert.True(StoredSessionCodec.DecodeFolder(StoredSessionCodec.Encode(header)).IsTidyHeader);

        Assert.IsType<NotATidyHeader>(Assert.Throws<Rejected>(() => device.Send(
            new CloseTidyHeader(device.Workspace, window, f.Space, f.OpenFolder))).Rejection);
        device.Send(new CloseTidyHeader(device.Workspace, window, f.Space, header.Id));

        var space = core.Current.Spaces[0];
        Assert.DoesNotContain(space.Folders, folder => folder.Id == header.Id);
        Assert.DoesNotContain(space.Tabs, tab => tab.Id == f.Open || tab.Id == f.Last);
        Assert.Contains(space.ArchivedTabs, archived => archived.Tab.Id == f.Open);
    }

    [Fact]
    public void ATidyHeaderMovedToSavedTabsBecomesAnOrdinaryFolder() {
        var f = new BatchSpace();
        using var device = new TestDevice(f.Session);
        var core = device.Authority;
        device.Send(new TidyCurrentTabs(device.Workspace, f.Space, [new("Reading", [f.Open, f.Last])]));
        var header = Assert.Single(core.Current.Spaces[0].Folders, folder => folder.IsTidyHeader);

        device.Send(new MoveFolder(device.Workspace, f.Space, header.Id, TabPlacement.Saved, null, null, null));

        var moved = Assert.Single(core.Current.Spaces[0].Folders, folder => folder.Id == header.Id);
        Assert.Same(TabPlacement.Saved, moved.Location);
        Assert.False(moved.IsTidyHeader);
    }
}
