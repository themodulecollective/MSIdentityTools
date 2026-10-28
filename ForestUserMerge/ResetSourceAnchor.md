# Re-anchoring a user that has already synced

The `ResetLegacyConsistencyGuidFromTargetUser` operation can't just overwrite `mS-DS-ConsistencyGuid`. The legacy
user is already joined to its own Entra user. Entra Connect won't move that join to a different Entra user, and
Entra rejects an `onPremisesImmutableId` change on a synced user. The old engagement script (since deleted) did it
in four steps:

1. **Take the legacy user out of sync scope.** Move it to an OU that Entra Connect doesn't sync (record the
   original parent DN first). Then, with the ADConsistencyGuid module:
   `Set-ADConsistencyGuid -Identity <legacy user> -ConsistencyGuid <target user's value> -Overwrite`.
2. **Run a delta sync and wait for the Entra user to go.** `Start-ADSyncSyncCycle -PolicyType Delta`, then poll
   Entra (`Get-MgUser -Filter "onPremisesImmutableId eq '<old ImmutableID>'"`) until the old user no longer
   comes back. The script retried the sync cycle when one was already running. It also re-ran it every eight
   minutes while waiting. Put a time limit on the wait; the original looped forever.
3. **Move the user back** to its original OU.
4. **Run another delta sync.** The legacy user now carries the target user's anchor, so it joins the same
   metaverse object and Entra user as the target user. (That needs the join rules in
   `ADConsistencyGuid/SyncRuleJoinPattern.md`.)

Before using it:

- The old Entra user goes to deleted users, and its licenses, mailbox, and OneDrive go with it. Only do this when
  the planner says the target user's Entra object is the one to keep: its UPN matches, and only it is licensed.
- The temporary OU must really be out of scope. Check Entra Connect's OU filtering, not just the OU's name.
- Moving many users out of scope at once can trip Entra Connect's accidental-deletion threshold. Work in small
  batches.
