using CrestCore.Application;

namespace CrestCore.Contracts;

/// Closes a header Tidy made: archives the open tabs directly under it and
/// removes the header, in one edit. The window then shows the tab it showed
/// before, when the one it showed was archived, or none. Refused with
/// `UnknownFolder` for a folder the Space does not hold and `NotATidyHeader`
/// for any other folder.
public sealed record CloseTidyHeader(Guid WorkspaceId, Guid WindowId, Guid SpaceId, Guid FolderId) : SessionIntent(WorkspaceId) {
    #region Actions - Session

    internal override SessionEdit? Edit(NativeSessionAuthority workspace, SessionTurn turn) {
        var space = turn.Basis.Spaces.FirstOrDefault(candidate => candidate.Id == SpaceId);
        var header = space?.Folders.FirstOrDefault(folder => folder.Id == FolderId) ?? throw new Rejected(new UnknownFolder(FolderId));
        if (!header.IsTidyHeader) throw new Rejected(new NotATidyHeader(FolderId));
        Guid[] headerTabIds = [.. space!.Tabs.Where(tab => tab.FolderId == FolderId).Select(tab => tab.Id)];
        var batch = workspace.Selecting(turn.Basis, WindowId, SpaceId, new(headerTabIds, [], headerTabIds));
        if (headerTabIds.Length > 0)
            batch.FollowUp.ShowTab(batch.Space.Id, batch.Edited.CloseSelected(batch.Selected, batch.Shown, batch.Fallback(), turn.Now));
        batch.Edited.DeleteFolder(FolderId, turn.Now);
        return batch.Result(turn.Basis, SyncStaging.Batch);
    }

    #endregion
}
