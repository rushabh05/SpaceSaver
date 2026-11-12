//! Windows path helpers: lexical normalisation, case-insensitive comparison and display.
//!
//! Everything here works on strings with Windows semantics, so the safety checks behave the
//! same whatever form a path arrives in (`/` or `\`, `\\?\` prefixes, `..`, trailing dots,
//! different letter case).

use std::path::Path;

/// Lexically normalises a Windows path.
///
/// * `/` becomes `\` and repeated separators collapse.
/// * `\\?\`, `\\?\UNC\` and `\\.\` prefixes are removed.
/// * `.` and `..` components are resolved (`..` never climbs above the root).
/// * Trailing dots and spaces are trimmed from each component, as Win32 does.
/// * The drive letter is upper-cased.
///
/// The result has no trailing separator, except for a drive root (`C:\`).
pub fn normalize(path: &str) -> String {
    let mut s = path.replace('/', "\\");
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        s = format!(r"\\{rest}");
    } else if let Some(rest) = s.strip_prefix(r"\\?\") {
        s = rest.to_string();
    } else if let Some(rest) = s.strip_prefix(r"\\.\") {
        s = rest.to_string();
    }

    let (prefix, rest): (String, &str) = if let Some(unc) = s.strip_prefix(r"\\") {
        let mut parts = unc.splitn(3, '\\');
        let server = parts.next().unwrap_or("");
        let share = parts.next().unwrap_or("");
        let rest = parts.next().unwrap_or("");
        (format!(r"\\{server}\{share}"), rest)
    } else if s.len() >= 2 && s.as_bytes()[1] == b':' && s.as_bytes()[0].is_ascii_alphabetic() {
        (s[..2].to_ascii_uppercase(), &s[2..])
    } else {
        (String::new(), s.as_str())
    };

    let mut parts: Vec<&str> = Vec::new();
    for comp in rest.split('\\') {
        let comp = if comp == "." || comp == ".." {
            comp
        } else {
            comp.trim_end_matches(|c: char| c == '.' || c == ' ')
        };
        match comp {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            c => parts.push(c),
        }
    }

    if prefix.is_empty() {
        return parts.join("\\");
    }
    if parts.is_empty() {
        return format!("{prefix}\\");
    }
    format!("{prefix}\\{}", parts.join("\\"))
}

/// Comparison key: the normalised path in lower case (NTFS paths are case-insensitive).
pub fn key(path: &str) -> String {
    normalize(path).to_lowercase()
}

/// Comparison key for a [`Path`].
pub fn key_of(path: &Path) -> String {
    key(&path.to_string_lossy())
}

/// True when `path` starts with a drive letter and a separator (`C:\`) or is a UNC path.
pub fn is_absolute(path: &str) -> bool {
    let b = path.as_bytes();
    if path.starts_with(r"\\") || path.starts_with("//") {
        return true;
    }
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/')
}

/// True when `child` equals `parent` or lies inside it. Both must be keys from [`key`].
pub fn is_within(child: &str, parent: &str) -> bool {
    if child == parent {
        return true;
    }
    let p = parent.trim_end_matches('\\');
    child.len() > p.len() && child.starts_with(p) && child.as_bytes()[p.len()] == b'\\'
}

/// The last component of a path.
pub fn name(path: &str) -> String {
    let n = normalize(path);
    n.rsplit('\\').next().unwrap_or("").to_string()
}

/// Shortens paths inside the user profile to `~\…` for display.
pub fn display(path: &str, home: &Path) -> String {
    let norm = normalize(path);
    let home_norm = normalize(&home.to_string_lossy());
    let (pk, hk) = (norm.to_lowercase(), home_norm.to_lowercase());
    if !home_norm.is_empty() && is_within(&pk, &hk) && pk.len() == norm.len() && hk.len() == home_norm.len() {
        let rest = &norm[home_norm.trim_end_matches('\\').len()..];
        return format!("~{rest}");
    }
    norm
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_prefixes_separators_and_dots() {
        assert_eq!(normalize(r"\\?\C:\Users\me\proj\"), r"C:\Users\me\proj");
        assert_eq!(normalize("c:/Users//me/./proj/../x"), r"C:\Users\me\x");
        assert_eq!(normalize(r"C:\Windows."), r"C:\Windows");
        assert_eq!(normalize(r"C:\Windows. . "), r"C:\Windows");
        assert_eq!(normalize(r"C:\..\.."), r"C:\");
        assert_eq!(normalize(r"\\?\UNC\server\share\dir"), r"\\server\share\dir");
        assert_eq!(normalize("C:"), r"C:\");
    }

    #[test]
    fn within_is_component_aware_and_case_insensitive() {
        assert!(is_within(&key(r"C:\Program Files\X"), &key(r"c:\program files")));
        assert!(!is_within(&key(r"C:\Program Files (x86)\X"), &key(r"C:\Program Files")));
        assert!(is_within(&key(r"C:\a"), &key(r"C:\")));
        assert!(!is_within(&key(r"C:\ab"), &key(r"C:\a")));
    }

    #[test]
    fn displays_home_relative() {
        let home = Path::new(r"C:\Users\Me");
        assert_eq!(display(r"c:\users\me\proj\node_modules", home), r"~\proj\node_modules");
        assert_eq!(display(r"D:\x", home), r"D:\x");
    }

    #[test]
    fn absolute_detection() {
        assert!(is_absolute(r"C:\x"));
        assert!(is_absolute("C:/x"));
        assert!(is_absolute(r"\\server\share"));
        assert!(!is_absolute(r"C:x"));
        assert!(!is_absolute(r"x\y"));
    }
}
