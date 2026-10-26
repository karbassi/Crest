using CrestCore.Application;
using CrestCore.Domain;

namespace CrestCore.Contracts;

#region Types

/// A header Tidy proposes, named in the app's language, and the tabs it holds.
public sealed record TidyFolderProposal(string FolderTitle, IReadOnlyList<Guid> TabIds);

#endregion

/// Files a Space's open tabs under the headers Tidy proposes, in one edit: each
/// header is made in the open section with its tabs. Only an open tab outside
/// every folder and split may be filed, each under at most one header. Refused
/// with `TabCannotBeTidied` for any other tab and `TidyFolderNeedsTwoTabs` for
/// a header of fewer than two, and then nothing changes.
public sealed record TidyCurrentTabs(Guid WorkspaceId, Guid SpaceId, IReadOnlyList<TidyFolderProposal> Folders)
    : SessionIntent(WorkspaceId) {
    #region Actions - Session

    internal override SessionEdit? Edit(NativeSessionAuthority workspace, SessionTurn turn) =>
        workspace.Organizing(turn.Basis, SpaceId, SyncStaging.Creation, edited => {
            RequireTidyableTabs(edited);
            foreach (var folder in Folders) {
                var folderId = turn.Ids.Next();
                edited.AddFolder(folderId, NativeSessionAuthority.FolderTitle(folder.FolderTitle), TabPlacement.Current,
                    isTidyHeader: true);
                edited.FileTabs(folder.TabIds, TabPlacement.Current, folderId, turn.Now);
            }
        });

    /// Checks every proposal before anything changes.
    private void RequireTidyableTabs(BrowserTabCollection edited) {
        var filedTabIds = new HashSet<Guid>();
        foreach (var folder in Folders) {
            if (folder.TabIds.Count < 2) throw new Rejected(new TidyFolderNeedsTwoTabs(folder.FolderTitle));
            foreach (var tabId in folder.TabIds) {
                if (!filedTabIds.Add(tabId)) throw new Rejected(new TabCannotBeTidied(tabId));
                var tab = edited.Tab(tabId);
                if (tab.Placement != TabPlacement.Current || tab.FolderId is not null || tab.SplitGroupId is not null)
                    throw new Rejected(new TabCannotBeTidied(tabId));
            }
        }
    }

    #endregion
}
