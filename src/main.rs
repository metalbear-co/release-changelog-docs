#!/usr/bin/env rust-script
//! Render towncrier histories for the public website without changing source release notes.
//!
//! ```cargo
//! [dependencies]
//! fancy-regex = "0.16"
//! chrono = { version = "0.4.42", features = ["now"] }
//! ```

use std::{
    env,
    error::Error,
    io::{self, Read, Write},
    ops::Not,
};

use chrono::{NaiveDate, Utc};
use fancy_regex::Regex;

struct Metadata {
    title: String,
    description: String,
    tags: Vec<String>,
    date: String,
}

struct SourceContext {
    url: String,
    sha: String,
    parent: Vec<String>,
}

impl SourceContext {
    fn new(url: &str, sha: &str, file: &str) -> Result<Self, Box<dyn Error>> {
        if [
            "https://github.com/metalbear-co/mirrord",
            "https://github.com/metalbear-co/mirrord-vscode",
            "https://github.com/metalbear-co/mirrord-intellij",
        ]
        .contains(&url)
        .not()
        {
            return Err(
                "PUBLIC_SOURCE_URL must be a supported canonical public repository URL".into(),
            );
        }

        if sha.len() != 40
            || sha
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                .not()
        {
            return Err("SOURCE_SHA must be 40 lowercase hexadecimal digits".into());
        }

        let mut parent = Vec::new();
        for segment in file.split('/') {
            if segment.is_empty()
                || matches!(segment, "." | "..")
                || segment
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._~-".contains(&byte))
                    .not()
            {
                return Err(
                    "SOURCE_FILE must be a normalized unreserved relative file path".into(),
                );
            }
            parent.push(segment.to_owned());
        }
        parent.pop();

        Ok(Self {
            url: url.to_owned(),
            sha: sha.to_owned(),
            parent,
        })
    }

    fn resolve(&self, destination: &str) -> Option<String> {
        let suffix_start = destination.find(['?', '#']).unwrap_or(destination.len());
        let (path, suffix) = destination.split_at(suffix_start);
        if path.is_empty()
            || path.starts_with('/')
            || destination.bytes().any(|byte| {
                byte.is_ascii_control()
                    || byte.is_ascii_whitespace()
                    || b"\\()<>\"'".contains(&byte)
            })
        {
            return None;
        }

        let mut resolved: Vec<_> = self.parent.iter().map(String::as_str).collect();
        for segment in path.split('/') {
            match segment {
                "." => {}
                ".." => {
                    resolved.pop()?;
                }
                "" => return None,
                _ if segment
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._~-".contains(&byte)) =>
                {
                    resolved.push(segment);
                }
                _ => return None,
            }
        }
        if resolved.is_empty() {
            return None;
        }

        Some(format!(
            "{}/blob/{}/{}{suffix}",
            self.url,
            self.sha,
            resolved.join("/")
        ))
    }

    fn rewrite_links(&self, paragraph: &str) -> String {
        let mut output = String::new();
        let mut copied = 0;
        let mut offset = 0;
        let mut code_until = 0;

        for line in paragraph.split_inclusive('\n') {
            let bytes = line.as_bytes();
            let indented =
                line.starts_with("    ") || line.trim_start_matches(' ').starts_with('\t');
            let container = line.trim_start().starts_with('>') || line.contains(['<', '>']);
            let eligible = indented.not() && container.not();
            let mut links = eligible;
            let mut index = 0;

            while index < bytes.len() {
                // A proven span can end on an excluded continuation line. Its bytes
                // stay untouched, but links after its closer must remain eligible.
                if offset + index < code_until {
                    index = (code_until - offset).min(bytes.len());
                    continue;
                }
                if eligible.not() {
                    break;
                }
                if bytes[index] == b'`' {
                    if let Some(end) = code_span_end(&paragraph[offset + index..]) {
                        code_until = offset + index + end;
                    }
                    index += bytes[index..].iter().take_while(|&&b| b == b'`').count();
                    continue;
                }
                if bytes[index] == b'\\' {
                    index += 2;
                    continue;
                }

                let image = bytes[index] == b'!' && bytes.get(index + 1) == Some(&b'[');
                if links.not() || (bytes[index] != b'[' && image.not()) {
                    index += 1;
                    continue;
                }

                // Scan the outer label first: historical labels include inline code.
                // Nested labels and images are consumed but deliberately not rewritten.
                let mut end = index + if image { 2 } else { 1 };
                let mut depth = 1;
                let mut nested = false;
                while end < bytes.len() {
                    match bytes[end] {
                        b'`' => {
                            end += code_span_end(&line[end..]).unwrap_or_else(|| {
                                bytes[end..].iter().take_while(|&&b| b == b'`').count()
                            });
                            continue;
                        }
                        b'\\' => {
                            end += 2;
                            continue;
                        }
                        b'[' => {
                            depth += 1;
                            nested = true;
                        }
                        b']' => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    end += 1;
                }
                if end >= bytes.len() {
                    // Multiline labels stay unsupported, but their remaining text
                    // can still open a valid code span continuing on the next line.
                    links = false;
                    index += 1;
                    continue;
                }
                index = end + 1;
                if bytes.get(index) != Some(&b'(') {
                    continue;
                }
                let start = index + 1;
                let mut close = start;
                let mut parentheses = 1;
                while close < bytes.len() {
                    match bytes[close] {
                        b'\\' => {
                            close += 2;
                            continue;
                        }
                        b'(' => parentheses += 1,
                        b')' => {
                            parentheses -= 1;
                            if parentheses == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    close += 1;
                }
                if close >= bytes.len() {
                    links = false;
                    continue;
                }
                index = close + 1;
                if image || nested || bytes.get(index) == Some(&b')') {
                    continue;
                }
                if let Some(destination) = self.resolve(&line[start..close]) {
                    output.push_str(&paragraph[copied..offset + start]);
                    output.push_str(&destination);
                    copied = offset + close;
                }
            }
            offset += line.len();
        }
        output.push_str(&paragraph[copied..]);
        output
    }
}

// A backtick run is literal unless an equal-length run closes it in this block.
// Return the byte after the closer so callers can preserve the whole code span.
fn code_span_end(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    let opening = bytes.iter().take_while(|&&b| b == b'`').count();
    let mut index = opening;

    while index < bytes.len() {
        if bytes[index] == b'`' {
            let length = bytes[index..].iter().take_while(|&&b| b == b'`').count();
            index += length;
            if length == opening {
                return Some(index);
            }
        } else {
            index += 1;
        }
    }

    None
}

fn main() -> Result<(), Box<dyn Error>> {
    let metadata_value = |key| -> Result<String, Box<dyn Error>> {
        let value = env::var(key).map_err(|_| format!("Missing {key}"))?;
        if value.trim().is_empty() || value.chars().any(char::is_control) {
            return Err(format!("{key} must be nonblank and single-line").into());
        }

        Ok(value)
    };
    let title = metadata_value("CHANGELOG_TITLE")?;
    let description = metadata_value("CHANGELOG_DESCRIPTION")?;
    let tags = metadata_value("CHANGELOG_TAGS")?;
    let date = metadata_value("CHANGELOG_DATE")?;

    let parsed_date = NaiveDate::parse_from_str(&date, "%Y-%m-%d")?;
    if parsed_date.to_string() != date {
        return Err("CHANGELOG_DATE must be YYYY-MM-DD".into());
    }

    let tags: Vec<_> = tags.split(',').map(|tag| tag.trim().to_owned()).collect();
    if tags.iter().any(|tag| tag.is_empty()) {
        return Err("Every CHANGELOG_TAGS entry must be nonblank".into());
    }

    let metadata = Metadata {
        title,
        description,
        tags,
        date,
    };

    let source = match env::var("PUBLIC_SOURCE_URL") {
        Ok(url) if url.is_empty().not() => Some(SourceContext::new(
            &url,
            &env::var("SOURCE_SHA")?,
            &env::var("SOURCE_FILE")?,
        )?),
        Ok(_) | Err(env::VarError::NotPresent) => None,
        Err(error) => return Err(error.into()),
    };

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let body = clean_changelog(&input, source.as_ref())?;

    let output = format!(
        "{}{body}\n",
        preamble_with_date(&metadata, Utc::now().date_naive())
    );
    io::stdout().write_all(output.as_bytes())?;

    Ok(())
}

fn clean_changelog(input: &str, source: Option<&SourceContext>) -> Result<String, Box<dyn Error>> {
    let marker = "<!-- towncrier release notes start -->";
    let input = match input.split_once(marker) {
        Some((_, history)) => history.trim_start_matches(['\r', '\n']),
        None => input,
    };

    let first_heading = Regex::new(r"^## (?:\[)?v?\d+\.\d+\.\d+(?:[ \]\r\n]|$)")?;
    if first_heading.is_match(input)?.not() {
        return Err("Changelog must start with a release heading or towncrier marker".into());
    }

    let heading = Regex::new(r"^## \[(v?\d+\.\d+\.\d+[^\]\r\n]*)\]\([^\r\n)]+\)")?;
    let private_issue =
        Regex::new(r"\s*\[#\d+\]\(https://github\.com/metalbear-co/operator/issues/\d+\)")?;

    let mut output = String::new();
    let mut release = String::new();
    let mut paragraph = String::new();
    let mut internal = false;
    let mut fence: Option<(char, usize)> = None;

    for line in input.split_inclusive('\n') {
        let trimmed = line.trim_start();
        let indentation = line.len() - trimmed.len();
        let fence_indentation = indentation <= 3 && line[..indentation].chars().all(|c| c == ' ');
        let fence_marker = trimmed.chars().next().filter(|c| *c == '`' || *c == '~');
        let fence_length = fence_marker.map_or(0, |marker| {
            trimmed.chars().take_while(|c| *c == marker).count()
        });
        let was_in_fence = fence.is_some();

        if let Some((character, length)) = fence {
            let closing_line = trimmed
                .strip_suffix("\r\n")
                .or_else(|| trimmed.strip_suffix('\n'))
                .unwrap_or(trimmed);

            // Released public examples append issue links to their closing markers.
            // Keep that compatibility while requiring real closures inside Internal.
            if fence_marker == Some(character)
                && fence_length >= length
                && (internal.not()
                    || (fence_indentation
                        && closing_line[fence_length..]
                            .chars()
                            .all(|c| matches!(c, ' ' | '\t'))))
            {
                fence = None;
            }
        } else if fence_length >= 3 && fence_indentation {
            fence = fence_marker.map(|character| (character, fence_length));
        }

        // Match inline code only within its public block. Blank lines, headings,
        // fences, quote containers and new list items cannot supply its closer.
        let hashes = trimmed.bytes().take_while(|&byte| byte == b'#').count();
        let atx_heading = fence_indentation
            && (1..=6).contains(&hashes)
            && (trimmed[hashes..].starts_with([' ', '\t', '\r', '\n']) || hashes == trimmed.len());
        let bullet = fence_indentation
            && trimmed
                .strip_prefix(['-', '+', '*'])
                .is_some_and(|rest| rest.starts_with([' ', '\t']));
        let after_number = trimmed.trim_start_matches(|c: char| c.is_ascii_digit());
        let numbered = fence_indentation
            && after_number.len() < trimmed.len()
            && after_number
                .strip_prefix(['.', ')'])
                .is_some_and(|rest| rest.starts_with([' ', '\t']));
        let thematic = fence_indentation
            && ['-', '*', '_'].iter().any(|&marker| {
                trimmed.chars().filter(|&c| c == marker).count() >= 3
                    && trimmed.chars().all(|c| c == marker || c.is_whitespace())
            });
        let separate_block = trimmed.is_empty()
            || atx_heading
            || thematic
            || (fence_indentation && trimmed.starts_with('>'))
            || was_in_fence
            || fence.is_some();

        if let Some(source) = source.filter(|_| separate_block || bullet || numbered) {
            release.push_str(&source.rewrite_links(&paragraph));
            paragraph.clear();
        }

        if was_in_fence.not() && line.starts_with("## ") {
            if release.is_empty().not() {
                output.push_str(&finish_release(&release));
                release.clear();
            }

            internal = false;
            release.push_str(&heading.replace(line, "## $1"));
        } else {
            if was_in_fence.not() && line.starts_with("### ") {
                internal = line.trim_end() == "### Internal";
            }

            if internal.not() {
                if let Some(source) = source {
                    if separate_block {
                        if was_in_fence.not() && fence.is_none() {
                            release.push_str(&source.rewrite_links(line));
                        } else {
                            release.push_str(line);
                        }
                    } else {
                        paragraph.push_str(line);
                    }
                } else {
                    release.push_str(line);
                }
            }
        }
    }

    if let Some(source) = source {
        release.push_str(&source.rewrite_links(&paragraph));
    }

    if release.is_empty() {
        return Err("Changelog contains no releases".into());
    }

    output.push_str(&finish_release(&release));

    Ok(private_issue.replace_all(&output, "").into_owned())
}

fn finish_release(release: &str) -> String {
    let (heading, body) = release.split_once('\n').unwrap_or((release, ""));

    if body.trim().is_empty() {
        // Keep the old renderer's spacing, also covering an Internal-only final release.
        let spacing = if body.is_empty() { "\n\n" } else { body };
        format!("{heading}\n\nNo significant changes.\n{spacing}")
    } else {
        release.to_owned()
    }
}

fn preamble_with_date(metadata: &Metadata, lastmod: NaiveDate) -> String {
    // Known presentation values retain their existing plain YAML spelling. Other
    // scalar values are quoted so caller data cannot introduce frontmatter keys.
    fn scalar(value: &str) -> String {
        if value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || " ._-".contains(c))
            && value
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic())
            && ["true", "false", "null", "yes", "no", "on", "off"]
                .contains(&value.to_ascii_lowercase().as_str())
                .not()
            && value.trim() == value
        {
            value.to_owned()
        } else {
            format!("'{}'", value.replace('\'', "''"))
        }
    }

    let tags = metadata
        .tags
        .iter()
        .map(|tag| format!("  - {}\n", scalar(tag)))
        .collect::<String>();

    format!(
        "---\n\
        title: {}\n\
        date: {}T00:00:00.000Z\n\
        lastmod: {lastmod}T00:00:00.000Z\n\
        draft: false\n\
        images: []\n\
        weight: 100\n\
        toc: true\n\
        tags:\n{tags}\
        description: >-\n  {}\n\
        ---\n\n",
        scalar(&metadata.title),
        metadata.date,
        metadata.description,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_history_and_internal_boundaries() {
        let input = include_str!("../tests/fixtures/boundaries.md");
        let expected = include_str!("../tests/fixtures/boundaries.expected.md");

        assert_eq!(
            clean_changelog(input, None).unwrap(),
            format!("{expected}\n\n")
        );
        let source = SourceContext::new(
            "https://github.com/metalbear-co/mirrord",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "CHANGELOG.md",
        )
        .unwrap();
        assert_eq!(
            clean_changelog(input, Some(&source)).unwrap(),
            format!("{expected}\n\n")
        );
    }

    #[test]
    fn indented_public_markers_do_not_hide_internal_sections() {
        let source = SourceContext::new(
            "https://github.com/metalbear-co/mirrord",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "CHANGELOG.md",
        )
        .unwrap();

        for indentation in ["    ", "\t", " \t"] {
            for marker in ["```", "~~~"] {
                let input = format!(
                    "## 1.2.3\n\n### Fixed\nPublic change.\n\n{indentation}{marker}\n\n\
                     ### Internal\nPRIVATE_SENTINEL\n\n### Added\nPublic continuation.\n"
                );
                let expected = format!(
                    "## 1.2.3\n\n### Fixed\nPublic change.\n\n{indentation}{marker}\n\n\
                     ### Added\nPublic continuation.\n"
                );

                for source in [None, Some(&source)] {
                    assert_eq!(
                        clean_changelog(&input, source).unwrap(),
                        expected,
                        "indentation={indentation:?}, marker={marker:?}, source={}",
                        source.is_some(),
                    );
                }
            }
        }
    }

    #[test]
    fn public_source_links_preserve_markdown_boundaries_and_default_output() {
        let input = include_str!("../tests/fixtures/links.md");
        let expected = include_str!("../tests/fixtures/links.expected.md");
        let source = SourceContext::new(
            "https://github.com/metalbear-co/mirrord",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "CHANGELOG.md",
        )
        .unwrap();

        assert_eq!(clean_changelog(input, Some(&source)).unwrap(), expected);
        assert_eq!(clean_changelog(input, None).unwrap(), input);
    }

    #[test]
    fn unmatched_historical_backtick_does_not_hide_later_links() {
        let source = SourceContext::new(
            "https://github.com/metalbear-co/mirrord",
            "a138a342a7012193ece9ff588d03698dab8b9057",
            "CHANGELOG.md",
        )
        .unwrap();
        let input = concat!(
            "## 3.25.0\n\n",
            "- filter: add `/private/var/folders\" to default local read override\n",
            "- filter: fixed regex for `/tmp` default local read override\n",
            "- disable flask e2e until we solve the glibc issue (probably fstream issue)\n\n",
            "[next paragraph](./paragraph.md).\n\n",
            "## 3.24.0\n\n",
            "[next release](./TELEMETRY.md).\n",
        );
        let expected = concat!(
            "## 3.25.0\n\n",
            "- filter: add `/private/var/folders\" to default local read override\n",
            "- filter: fixed regex for `/tmp` default local read override\n",
            "- disable flask e2e until we solve the glibc issue (probably fstream issue)\n\n",
            "[next paragraph](https://github.com/metalbear-co/mirrord/blob/a138a342a7012193ece9ff588d03698dab8b9057/paragraph.md).\n\n",
            "## 3.24.0\n\n",
            "[next release](https://github.com/metalbear-co/mirrord/blob/a138a342a7012193ece9ff588d03698dab8b9057/TELEMETRY.md).\n",
        );

        assert_eq!(clean_changelog(input, Some(&source)).unwrap(), expected);
    }

    #[test]
    fn nested_source_links_resolve_against_the_selected_file_parent() {
        let source = SourceContext::new(
            "https://github.com/metalbear-co/mirrord-vscode",
            "0123456789abcdef0123456789abcdef01234567",
            "docs/history/CHANGELOG.md",
        )
        .unwrap();
        let input = concat!(
            "## [3.10.0](https://example.com/release)\n\n",
            "[telemetry](../../TELEMETRY.md?raw=1#policy) ",
            "[`FileFilter`](.././guide/../file.rs) ",
            "[above](../../../private.md)\n",
            "### Internal\nPRIVATE_LINK [hidden](../../secret.md)\n",
            "### Fixed\nVisible [#12](https://github.com/metalbear-co/operator/issues/12)\n",
        );
        let expected = concat!(
            "## 3.10.0\n\n",
            "[telemetry](https://github.com/metalbear-co/mirrord-vscode/blob/0123456789abcdef0123456789abcdef01234567/TELEMETRY.md?raw=1#policy) ",
            "[`FileFilter`](https://github.com/metalbear-co/mirrord-vscode/blob/0123456789abcdef0123456789abcdef01234567/docs/file.rs) ",
            "[above](../../../private.md)\n",
            "### Fixed\nVisible\n",
        );

        assert_eq!(clean_changelog(input, Some(&source)).unwrap(), expected);
    }

    #[test]
    fn enabled_source_context_rejects_noncanonical_values() {
        let url = "https://github.com/metalbear-co/mirrord";
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        for invalid in [
            "https://github.com/metalbear-co/operator",
            "https://github.com/metalbear-co/mirrord/",
            "https://github.com/metalbear-co/mirrord?raw=1",
            "https://github.com/metalbear-co/mirrord#section",
            "https://github.com/metalbear-co/mirrord/blob/main",
            "https://user@github.com/metalbear-co/mirrord",
            "https://github.com/metalbear-co/mirrord\n",
        ] {
            assert!(SourceContext::new(invalid, sha, "CHANGELOG.md").is_err());
        }
        for invalid in ["main", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "abc"] {
            assert!(SourceContext::new(url, invalid, "CHANGELOG.md").is_err());
        }
        for invalid in [
            "",
            "/CHANGELOG.md",
            "./CHANGELOG.md",
            "docs/../CHANGELOG.md",
            "docs//CHANGELOG.md",
            "docs/",
            "docs\\CHANGELOG.md",
            "a b.md",
            "a%20b.md",
            "CHANGELOG.md\n",
            "é.md",
        ] {
            assert!(SourceContext::new(url, sha, invalid).is_err());
        }
    }

    #[test]
    fn only_private_numeric_issue_references_are_removed() {
        let input = concat!(
            "## [3.10.0](https://example.com/release) - 2026-10-21\n\n",
            "- Fixed [#12](https://github.com/metalbear-co/operator/issues/12) ",
            "and [public](https://example.com/issues/12).\n",
            "- Wrapped\n",
            "  [#34](https://github.com/metalbear-co/operator/issues/34)\n",
            "- Keep [#1](https://github.com/metalbear-co/mirrord/issues/1) ",
            "[#2](https://github.com/metalbear-co/operator/pull/2) ",
            "[details](https://github.com/metalbear-co/operator/issues/3).\n",
        );
        let expected = concat!(
            "## 3.10.0 - 2026-10-21\n\n",
            "- Fixed and [public](https://example.com/issues/12).\n",
            "- Wrapped\n",
            "- Keep [#1](https://github.com/metalbear-co/mirrord/issues/1) ",
            "[#2](https://github.com/metalbear-co/operator/pull/2) ",
            "[details](https://github.com/metalbear-co/operator/issues/3).\n",
        );

        assert_eq!(clean_changelog(input, None).unwrap(), expected);
    }

    #[test]
    fn invalid_input_cannot_become_a_page() {
        for input in [
            "",
            "intro\n## 3.0.0\n",
            "<!-- towncrier release notes start -->\n",
            "## Not a release\n\nText\n",
        ] {
            assert!(clean_changelog(input, None).is_err());
        }
    }

    #[test]
    fn fixed_operator_preamble_is_compatible_and_scalars_are_safe() {
        let mut metadata = Metadata {
            title: "Operator Changelog".into(),
            description: "The release changelog for the mirrord operator.".into(),
            tags: vec!["team".into(), "enterprise".into()],
            date: "2023-08-15".into(),
        };
        let lastmod = NaiveDate::from_ymd_opt(2026, 10, 21).unwrap();
        let expected = concat!(
            "---\n",
            "title: Operator Changelog\n",
            "date: 2023-08-15T00:00:00.000Z\n",
            "lastmod: 2026-10-21T00:00:00.000Z\n",
            "draft: false\n",
            "images: []\n",
            "weight: 100\n",
            "toc: true\n",
            "tags:\n",
            "  - team\n",
            "  - enterprise\n",
            "description: >-\n",
            "  The release changelog for the mirrord operator.\n",
            "---\n\n",
        );

        assert_eq!(preamble_with_date(&metadata, lastmod), expected);

        metadata.title = "a: 'title'".into();
        metadata.tags = vec!["true".into(), "#tag".into()];
        let output = preamble_with_date(&metadata, lastmod);

        assert!(output.contains("title: 'a: ''title'''\n"));
        assert!(output.contains("  - 'true'\n  - '#tag'\n"));
    }
}
