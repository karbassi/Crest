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
}
