# Source introduction

<!-- towncrier release notes start -->

## [3.10.0](https://example.com/releases/3.10.0) - 2026-10-21

### Added

- Public text mentions ## inside a sentence.

### Internal

- Private detail with ## inside prose.

```text
```bash
## 99.0.0
### Fixed
PRIVATE_SENTINEL
``` 
### Fixed
PRIVATE_NON_HORIZONTAL_WHITESPACE_SENTINEL
    ```
### Fixed
PRIVATE_FOUR_SPACE_SENTINEL
	```
### Fixed
PRIVATE_TAB_INDENT_SENTINEL
 ```
### Fixed
PRIVATE_UNICODE_INDENT_SENTINEL
``
### Fixed
PRIVATE_SHORT_MARKER_SENTINEL
~~~
### Fixed
PRIVATE_WRONG_MARKER_SENTINEL
``` [example](https://example.com)
### Fixed
PRIVATE_LINK_SUFFIX_SENTINEL
```
### Fixed
PRIVATE_CONTROL_SUFFIX_SENTINEL
   ```` 	

### Added

- Public entry after the real closing fence.

### Fixed

- Keep public fix.

### Internal

~~~text
~~~bash
### Fixed
PRIVATE_TILDE_SENTINEL
~~~

### Added

- Public entry after a matching tilde closure.

## 3.9.0 - 2026-10-20

Maintenance build.

  ```toml
  [feature.fs.mapping]
  "/var/app/temp" = "/tmp"
  ``` [#2068](https://github.com/metalbear-co/mirrord/issues/2068)

### Internal

- Private detail after a public historical example.

   ```text
### Fixed
PRIVATE_THREE_SPACE_FENCE_SENTINEL
   ```

    ```text
    PRIVATE_FOUR_SPACE_PEER_CODE_SENTINEL
    ```

### Added

- PUBLIC_FOUR_SPACE_PEER_SENTINEL

### Internal

    ```text
    PRIVATE_FOUR_SPACE_RELEASE_CODE_SENTINEL
    ```

## 3.8.2 - 2026-10-19

- PUBLIC_FOUR_SPACE_RELEASE_SENTINEL

### Internal

	```text
	PRIVATE_TAB_PEER_CODE_SENTINEL
	```

 	```text
 	PRIVATE_SPACE_TAB_CODE_SENTINEL
 	```

### Added

- PUBLIC_TAB_PEER_SENTINEL

### Internal

	```text
	PRIVATE_TAB_RELEASE_CODE_SENTINEL
	```

## 3.8.1 - 2026-10-19

- PUBLIC_TAB_RELEASE_SENTINEL

## [3.8.0](https://example.com/releases/3.8.0) - 2026-10-19


### Internal

- Internal-only release.

## 3.7.1 - 2026-10-18

### Internal
- Internal-only release with the historical short spacing.

## 3.7.0 - 2026-10-18


### Internal

- Internal-only final release.

```text
```bash
### Added
PRIVATE_UNCLOSED_SENTINEL
