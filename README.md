# Sergeykolosov Tap

## How do I install these formulae?

`brew install sergeykolosov/tap/<formula>`

Or `brew tap sergeykolosov/tap`, `brew trust --formula sergeykolosov/tap/<formula>`
and then `brew install <formula>`.

Or, in a `brew bundle` `Brewfile`:

```ruby
tap "sergeykolosov/tap"
brew "sergeykolosov/tap/<formula>", trusted: true
```

Homebrew requires explicit [tap trust](https://docs.brew.sh/Tap-Trust) for
non-official taps; installing by fully qualified name trusts only that formula.

## Documentation

`brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
