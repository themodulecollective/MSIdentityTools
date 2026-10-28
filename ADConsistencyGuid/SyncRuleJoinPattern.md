# Joining objects across forests on mS-DS-ConsistencyGuid

A reference note kept from an old engagement's custom Entra Connect (AAD Connect) rules. Two forests were synced
to one tenant while their users were being merged. Some people had an object in both forests: a user in one and a
contact or a second user in the other. Entra had to see one person, not two.

## The pattern

1. **Stamp the same value on both objects.** Give the second forest's object the `mS-DS-ConsistencyGuid` of the
   object that already syncs. `Set-ADConsistencyGuid -ConsistencyGuid` in this module does that.
2. **Flow it into the metaverse.** Clone each default inbound rule involved (`In from AD - User Join`,
   `In from AD - Contact Join`, `In from AD - Group Join`) and add a Direct flow from `mS-DS-ConsistencyGuid` to a
   metaverse attribute of the same name. If the metaverse does not have that attribute, add it first in the
   Synchronization Service Manager's Metaverse Designer.
3. **Join on it.** In the forest whose objects should merge into existing metaverse objects, use a *Join* rule, not
   a *Provision* rule, so its objects never create metaverse objects of their own. The group rule joined on either
   condition below, so objects already joined the default way stayed joined while the value was being rolled out:
   - `objectGUID` to `sourceAnchorBinary` (the default join)
   - `mS-DS-ConsistencyGuid` to `mS-DS-ConsistencyGuid` (the new one)

The rest of each rule, including the `cloudFiltered` and `mailEnabled` expressions and the
`isCriticalSystemObject` / `adminDescription` scoping filters, was copied unchanged from Microsoft's defaults.
Take those from the Synchronization Rules Editor on the current version rather than from an old export, because
they change between releases.

## Mechanics worth remembering

- Never edit a default rule; an upgrade overwrites it. Clone it, give the clone a precedence below 100 (lower
  number wins), and disable the original.
- The editor's **Export** button writes the `New-ADSyncRule` / `Add-ADSyncAttributeFlowMapping` /
  `Add-ADSyncJoinConditionGroup` script for any rule. That's the quickest way to copy a rule between servers or
  keep it in source control. Replace the connector GUIDs with values looked up on the target server
  (`Get-ADSyncConnector`).
- Run a full synchronization after changing join rules, and check the connector space for objects that became
  disconnectors before the next export to Entra.
