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

fn main() -> Result<(), Box<dyn Error>> {
    let mut values = Vec::new();
    for key in [
        "CHANGELOG_TITLE",
        "CHANGELOG_DESCRIPTION",
        "CHANGELOG_TAGS",
        "CHANGELOG_DATE",
    ] {
        let value = env::var(key).map_err(|_| format!("Missing {key}"))?;
        if value.trim().is_empty() || value.chars().any(char::is_control) {
            return Err(format!("{key} must be nonblank and single-line").into());
        }
        values.push(value);
    }
    let date = values.pop().ok_or("Missing date")?;
    let parsed = NaiveDate::parse_from_str(&date, "%Y-%m-%d")?;
    if parsed.to_string() != date {
        return Err("CHANGELOG_DATE must be YYYY-MM-DD".into());
    }
    let tags: Vec<_> = values[2]
        .split(',')
        .map(|tag| tag.trim().to_owned())
        .collect();
    if tags.iter().any(|tag| tag.is_empty()) {
        return Err("Every CHANGELOG_TAGS entry must be nonblank".into());
    }
    let metadata = Metadata {
        title: values[0].clone(),
        description: values[1].clone(),
        tags,
        date,
    };
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let body = clean_changelog(&input)?;
    let output = format!(
        "{}{body}\n",
        preamble_with_date(&metadata, Utc::now().date_naive())
    );
    io::stdout().write_all(output.as_bytes())?;
    Ok(())
}

fn clean_changelog(input: &str) -> Result<String, Box<dyn Error>> {
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
    let mut internal = false;
    let mut fence: Option<(char, usize)> = None;
    for line in input.split_inclusive('\n') {
        let trimmed = line.trim_start();
        let fence_marker = trimmed.chars().next().filter(|c| *c == '`' || *c == '~');
        let fence_length = fence_marker.map(|c| trimmed.chars().take_while(|v| *v == c).count());
        let in_fence = fence.is_some();
        if let Some((character, length)) = fence {
            let closing_line = trimmed
                .strip_suffix("\r\n")
                .or_else(|| trimmed.strip_suffix('\n'))
                .unwrap_or(trimmed);
            let indentation = line.len() - trimmed.len();
            // Released public examples append issue links to their closing markers.
            // Keep that compatibility while requiring real closures inside Internal.
            if fence_marker == Some(character)
                && fence_length.unwrap_or(0) >= length
                && (internal.not()
                    || (indentation <= 3
                        && line[..indentation].chars().all(|c| c == ' ')
                        && closing_line[fence_length.unwrap_or(0)..]
                            .chars()
                            .all(|c| matches!(c, ' ' | '\t'))))
            {
                fence = None;
            }
        } else if let Some(length) = fence_length.filter(|length| *length >= 3) {
            fence = fence_marker.map(|character| (character, length));
        }
        if in_fence.not() && line.starts_with("## ") {
            if release.is_empty().not() {
                output.push_str(&finish_release(&release));
                release.clear();
            }
            internal = false;
            release.push_str(&heading.replace(line, "## $1"));
        } else {
            if in_fence.not() && line.starts_with("### ") {
                internal = line.trim_end() == "### Internal";
            }
            if internal.not() {
                release.push_str(line);
            }
        }
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
        assert_eq!(clean_changelog(input).unwrap(), format!("{expected}\n\n"));
    }

    #[test]
    fn only_private_numeric_issue_references_are_removed() {
        let input = "## [3.10.0](https://example.com/release) - 2026-10-21\n\n- Fixed [#12](https://github.com/metalbear-co/operator/issues/12) and [public](https://example.com/issues/12).\n- Wrapped\n  [#34](https://github.com/metalbear-co/operator/issues/34)\n- Keep [#1](https://github.com/metalbear-co/mirrord/issues/1) [#2](https://github.com/metalbear-co/operator/pull/2) [details](https://github.com/metalbear-co/operator/issues/3).\n";
        assert_eq!(clean_changelog(input).unwrap(), "## 3.10.0 - 2026-10-21\n\n- Fixed and [public](https://example.com/issues/12).\n- Wrapped\n- Keep [#1](https://github.com/metalbear-co/mirrord/issues/1) [#2](https://github.com/metalbear-co/operator/pull/2) [details](https://github.com/metalbear-co/operator/issues/3).\n");
    }

    #[test]
    fn invalid_input_cannot_become_a_page() {
        for input in [
            "",
            "intro\n## 3.0.0\n",
            "<!-- towncrier release notes start -->\n",
            "## Not a release\n\nText\n",
        ] {
            assert!(clean_changelog(input).is_err());
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
        let date = NaiveDate::from_ymd_opt(2026, 10, 21).unwrap();
        assert_eq!(preamble_with_date(&metadata, date), "---\ntitle: Operator Changelog\ndate: 2023-08-15T00:00:00.000Z\nlastmod: 2026-10-21T00:00:00.000Z\ndraft: false\nimages: []\nweight: 100\ntoc: true\ntags:\n  - team\n  - enterprise\ndescription: >-\n  The release changelog for the mirrord operator.\n---\n\n");
        metadata.title = "a: 'title'".into();
        metadata.tags = vec!["true".into(), "#tag".into()];
        let output = preamble_with_date(&metadata, date);
        assert!(output.contains("title: 'a: ''title'''\n"));
        assert!(output.contains("  - 'true'\n  - '#tag'\n"));
    }
}
