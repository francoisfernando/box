box
===

Querying and configuration-free ssh access to servers.

### Usage

```
# Get the address of a random server matching the filter
box ip vapour:live
box ip vapour:lab
box ip vapour:dev

# Get the address of a specific server
box ip vapour:dev:kermit.green
box ip ::kermit.green.493

# SSH to a random server matching the filter
box ssh vapour:lab

# SSH to a specific server
box ssh vapour:dev:kermit.green

# List available servers
box ls
box ls vapour
box ls :live
box ls :dev
```

### Filters

As shown above, `box` commands accept a filter as an argument.

A filter takes one of the following forms:

```
CLIENT
CLIENT:FLAVOUR
CLIENT:FLAVOUR:NAME
```

All of the components of the filter are optional, although for most commands
you need to specify at least one of the parts. For example, you could choose
the last form, but omit the `CLIENT` and `FLAVOUR` components if you only
wanted to filter using a `NAME`:

```
::waldorf.golden
```

### Random Servers?

For `box ip` and `box ssh` we pick a random target server which matches the
filter specified. The thinking behind this is that we get a load balancing
effect, so not everyone is hammering the same server.

`box ssh` also chooses a random gateway to bounce through for the same reason.

### Completion Support

#### Bash

For bash completion, you need to source the `box-completion.bash` from
your `.bashrc` or `.bash_profile`.

#### Z Shell

For zsh completion, you need to copy or symlink `_box.zsh` to directory in
your `fpath` and make sure it is called `_box`.

For example, I have created a symlink:

```sh
ln -s $HOME/src/ambiata/box/_box.zsh $HOME/.config/zsh/completions/_box
```

and I have the following in my `.zshrc`:

```zsh
fpath=($HOME/.config/zsh/completions $fpath)
```

#### Ambiata App Shop

It would be nice if we had a way to distribute these kind of auxiliary
scripts as part of an `appshop-update`.
