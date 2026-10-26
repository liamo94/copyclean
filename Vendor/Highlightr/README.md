Vendored from [raspu/Highlightr](https://github.com/raspu/Highlightr) 2.3.0 (`05e7fcc`), MIT licensed.

Local changes in `src/classes/Theme.swift`'s CSS parsing:

- `@media` blocks are dropped. Their rules were read as top-level ones, so the a11y themes' Windows high-contrast block (`color:highlight`) turned strings, numbers and comments gray.
- CSS colour names (`gold`, `navy`, `grey`, …), `rgb()`/`rgba()` and `#rgba`/`#rrggbbaa` parse instead of falling back to gray.
- `color:inherit` is ignored rather than parsed as gray.
- A named `.hljs` background (far's `navy`) no longer crashes.

Still unsupported: `var(--…)`, which the cybertopia themes use.

In `src/classes/Highlightr.swift`: `ignoreIllegals` defaults to `true`. With `false`, one illegal token (an unquoted JSON key, say) left the whole input uncoloured, and text being edited is invalid most of the time.

And in the a11y themes' CSS: `.hljs-attr` and `.hljs-property` (JSON/YAML keys, HTML attributes, object properties) join the title colour. Upstream leaves them unstyled, so keys showed in plain text colour while presenting.
