# Languages

Screenshot Note follows the preferred system/application language using `Locale.preferredLanguages`. Czech (`cs`, including `cs-CZ`) and English (`en`, including regional variants) are supported. Unsupported language preferences fall back to English. No user content or configuration names are automatically translated.

Interface strings live in `Localizations/cs.lproj/Localizable.strings` and `Localizations/en.lproj/Localizable.strings`. The original Czech string serves as the stable key. `L` handles static strings; `LF` handles format strings. Both catalogs must have identical keys and compatible format placeholders. The build script copies both localization bundles into the app. `Info.plist` declares the supported localizations.

Markdown output keeps the Screenshot heading stable and localizes Comment/Komentář. Previous-session discovery accepts both headings, so changing the UI language does not hide old sessions. User titles, comments, folder paths, filenames already saved and configuration names remain as entered.

Regression tests validate system-language selection and every key in both catalogs, then export and rediscover Czech and English Markdown notes without changing user content. You can inspect the effective language without opening a window:

```sh
ScreenshotNote -AppleLanguages '(en)' --language-check
ScreenshotNote -AppleLanguages '(cs)' --language-check
```

`--design-export DIRECTORY` renders all principal screens, the compact state and the About window in both languages and both appearances. Previews use temporary synthetic data and do not change saved configurations.
