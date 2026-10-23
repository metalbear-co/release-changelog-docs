## 3.10.0

- See [telemetry](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/TELEMETRY.md).
- Configure [`FileFilter`](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/mirrord-layer/src/file/filter.rs) and [`fs`](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/mirrord-config/src/fs.rs).
- Read [details](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/docs/file.md?raw=1#section).
- Keep [absolute](https://example.com/file), [mail](mailto:a@example.com), [data](data:text/plain,hello), [protocol](//example.com/file), [anchor](#section), [query](?raw=1), [root](/TELEMETRY.md), [above](../TELEMETRY.md).
- Keep ![image](./image.png), [reference][target], [shortcut], [title](./file.md "title").
- Keep [escaped](./file\ name.md), [parens](./file(one).md), [nested [label](./inner.md)](./outer.md).
- Keep [angle](<./file.md>).
- Escaped \[label](./escaped.md) and \![ordinary](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/ordinary.md).
- Inline `[code](./inline.md)` and ``[code `tick`](./multi.md)`` stay literal.
- A code span crosses lines: ``[code](./first.md)
[code](./second.md)`` then [real](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/after.md).
- A multiline [label
](./multiline.md) stays unchanged.

[target]: ./reference.md
<a href="./html.md">[label](./html-label.md)</a>
> [quoted](./quoted.md)
    [indented](./indented.md)
	[tabbed](./tabbed.md)

```markdown
[fenced](./fenced.md)
```
~~~markdown
[tilde](./tilde.md)
~~~

Prose [ then `code
[literal](./inside.md)` and [real](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/after.md).

Prose `code
[literal](./inside.md) <x>`
[real](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/after.md).

Prose `code
    [literal](./inside.md)`
[real](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/after.md).

日本語 [café](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/guide.md?q=é#日本) after.

An unmatched ` before [ordinary](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/unmatched.md).

Unequal runs ` and `` before [ordinary](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/unequal.md).

Prose ``code
    - [literal](./inside.md)` still code
    [literal](./second.md)``
[real](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/after.md).

Unmatched ` before [ordinary](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/heading.md).
### Fixed
`literal` and [ordinary](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/after-heading.md).

- Unmatched ` before [ordinary](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/item.md).
- `literal` and [ordinary](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/next-item.md).

- filter: add `/private/var/folders" to default local read override
- filter: fixed regex for `/tmp` default local read override
- disable flask e2e until we solve the glibc issue (probably fstream issue)

[next paragraph](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/paragraph.md).

## 3.24.0

[next release](https://github.com/metalbear-co/mirrord/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/TELEMETRY.md).
