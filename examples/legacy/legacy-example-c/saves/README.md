# Sample old saves (synthetic)

DataStore2 ("OrderedBackups") stores each player's combined data in two stores named
`DATA/<userId>`: an OrderedDataStore of versions (key = value = the version number) and a
DataStore holding the value under the newest version's key. The coins backup is the DataStore
`CoinsBackup`, key `<userId>`. Each JSON file lists the entries for one player exactly as stored.
No real player's data: the user ids are made up.

- `player-3001.json`: a typical player (3 saved versions; the newest is the one that counts).
- `player-3002.json`: a player whose coin backup is HIGHER than DataStore2's coins (the old game
  restored the backup at join).
- `player-3003.json`: a player with an active boost and no backup entry.
