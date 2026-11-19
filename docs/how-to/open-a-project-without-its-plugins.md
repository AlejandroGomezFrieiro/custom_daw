# How to open a project without its plugins

This guide shows you how to open a project when a plugin crashes, hangs,
or is slow to load. For each way and flag, see
[Plugins](../reference/plugins.md#offline-devices).

1. Open the project with its plugins offline:
   - From the shell: `paw --plugins-offline song`.
   - From paw: `:edit song offline`.
   - After a crash: `:recover`, then select an entry with
     "(plugins offline)".
2. paw opens the project. Each plugin shows as offline. The tracks play
   without the plugins.
3. To find the plugin with the problem, set the plugins online one at a
   time. In the device panel, select a device and press `o`.
4. If a plugin crashes again, press `o` on it again to keep it offline.
5. To set all the other plugins online, type `:plugins.online`.
6. Save the project. The offline flags are saved with it.

If a plugin failed while the project opened, paw records it. The next
time, paw opens the project with that plugin offline, and a message says
so. To open the project with all its plugins, type
`:edit song online`.
