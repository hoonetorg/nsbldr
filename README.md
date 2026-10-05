# Nsbldr

Used for building a container containing Ansible. 

Container can be built, exported, imported with script

Ansible can be run interactively in Container. 

Global config files for defining locations of roles, playbooks etc.

Host config files for defining locations of inventories files etc.

## Large files

`ansiblelargefilesdir` (required, in the environment's hostconf next to `ansiblefilesdir`): a host directory
for large files (downloads, installers, ISOs, later local package repos) that don't belong into the
git-managed input dirs. It is mounted to `/srv/ansible/largefiles` in the container and packed into the
encrypted bundle (`largefiles/`), so a bundle on a stick carries everything needed offline. With
`--workspace-root` it is `<workspace_root>/largefiles`.

```json
"ansiblelargefilesdir": "/srv/work/nsbldr/ano-ansiblelargefiles"
```

One directory per environment keeps environments apart, e.g.
`/srv/work/nsbldr/secretenv2-ansiblelargefiles/desktops-vienna` and `.../desktops-newyork`.
