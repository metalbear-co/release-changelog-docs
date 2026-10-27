## 3.10.0

- See [telemetry](./TELEMETRY.md).
- Configure [`FileFilter`](mirrord-layer/src/file/filter.rs) and [`fs`](mirrord-config/src/fs.rs).
- Read [details](docs/./guide/../file.md?raw=1#section).
- Keep [absolute](https://example.com/file), [mail](mailto:a@example.com), [data](data:text/plain,hello), [protocol](//example.com/file), [anchor](#section), [query](?raw=1), [root](/TELEMETRY.md), [above](../TELEMETRY.md).
- Keep ![image](./image.png), [reference][target], [shortcut], [title](./file.md "title").
- Keep [escaped](./file\ name.md), [parens](./file(one).md), [nested [label](./inner.md)](./outer.md).
- Keep [angle](<./file.md>).
- Escaped \[label](./escaped.md) and \![ordinary](./ordinary.md).
- Inline `[code](./inline.md)` and ``[code `tick`](./multi.md)`` stay literal.
- A code span crosses lines: ``[code](./first.md)
[code](./second.md)`` then [real](./after.md).
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
[literal](./inside.md)` and [real](./after.md).

Prose `code
[literal](./inside.md) <x>`
[real](./after.md).

Prose `code
    [literal](./inside.md)`
[real](./after.md).

日本語 [café](./guide.md?q=é#日本) after.

An unmatched ` before [ordinary](./unmatched.md).

Unequal runs ` and `` before [ordinary](./unequal.md).

Prose ``code
    - [literal](./inside.md)` still code
    [literal](./second.md)``
[real](./after.md).

Unmatched ` before [ordinary](./heading.md).
### Fixed
`literal` and [ordinary](./after-heading.md).

- Unmatched ` before [ordinary](./item.md).
- `literal` and [ordinary](./next-item.md).

- filter: add `/private/var/folders" to default local read override
- filter: fixed regex for `/tmp` default local read override
- disable flask e2e until we solve the glibc issue (probably fstream issue)

[next paragraph](./paragraph.md).

## 3.24.0

[next release](./TELEMETRY.md).
