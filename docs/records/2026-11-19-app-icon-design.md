# The app icon: two bubbles on ink

```
Status: decided
Date: 2026-11-19
Question: What should qot's app icon be, and which colours and background
          hold up in Icon Composer's appearances (dark, clear, tinted)?
```

## Answer

An amber disc with a smaller off-white dot set into its lower right, on an
ink background ("N1" on the design sheet). It is decided but not built: the
shipped icon is still the ring and dot until #105 is done.

- **Shape**: a large solid disc and a smaller solid dot, separated by a
  narrow gap. It reads two ways at once: a thought bubble drawn with two
  bubbles, and an abstract Q (quantum).
- **Colours**: disc amber `#f5b83d`, dot off-white `#f2f0ea`, background ink
  `#16161d` (the PWA's dark theme; the palette was settled on 2026-11-17 in
  the same exploration). The dot is the brightest element on purpose (see
  "What Icon Composer asks" and "Associations to avoid").
- **Geometry** on a 512 px canvas: disc centre (244, 244) radius 152; dot
  centre (352, 352) radius 60; a circle of radius 68 around the dot is cut
  out of the disc, leaving an 8 px gap.
- **Background**: ink for both the default and the dark appearance. Amber is
  a light colour: it is 10.1:1 against ink and only 1.7:1 against paper
  `#fbfaf7`, so a light background would make the main shape faint.
- **The gap is real geometry**, cut out of the disc layer, not a circle
  painted in the background colour (see "What Icon Composer asks of the
  design").

## Is a near-black background a problem?

No on iPhone, iPad, Mac and the web; yes on Apple Watch, where it gets
lightened.

- **Apple's guidelines have no rule against a dark background** for iOS,
  iPadOS or macOS. What they ask of a background is that it "stands out and
  emphasizes foreground content" and is simple (a solid colour or gradient).
  Ink does both for amber: 10.1:1, against 1.7:1 on paper.
- **The one explicit rule is for watchOS**: "Avoid using black for your
  icon's background. Lighten a black background so the icon doesn't blend
  into the display background." The Watch's screen is black, so a black
  icon loses its edge. The Watch version of the icon gets a lighter
  background (#105).
- **The real cost on iPhone is blending into a dark wallpaper**, where the
  icon's outline is harder to see. The system draws an edge highlight on
  every icon, and ink is a blue-tinted near-black (`#16161d`), not pure
  black, but this is the thing to look at on a device. Apple's own "system
  dark" background is tuned for this and is the alternative to compare
  against in Icon Composer.
- **Default and dark look alike.** A dark-background icon has almost nothing
  to change for the dark appearance. That costs nothing; it only means the
  icon doesn't shift when the phone goes dark.
- **For the dark appearance** the guidelines say "color backgrounds generally
  offer the greatest contrast in dark icons". That is advice against flat
  black, another reason to try the system dark background, or a slightly
  lifted ink, beside plain ink.
- Several of Apple's own icons have dark backgrounds by default (Stocks,
  Clock, Calculator, Wallet, Voice Memos). This is from memory, not checked
  against the sources below.
- Clear and tinted appearances ignore the background colour: the system
  replaces it with glass or the person's tint.

If this is revisited: the cheap fix is a lighter or system background behind
the same two bubbles, not a new design.

## What Icon Composer asks of the design

From Apple's documentation and two WWDC sessions (sources below). The
rendering details are Apple's and change between OS versions; the mock-ups
on the design sheets are hand-drawn approximations, so the real check is
Icon Composer's own preview.

- **Six appearances from three annotations.** People can set Home Screen
  icons to default, dark, clear (light and dark) or tinted (light and dark).
  The designer annotates three: default, dark and **mono**. Mono is a
  greyscale version from which the system makes all four clear and tinted
  appearances. The person picks the tint colour, so it can be anything.
- **Colour does not survive mono; lightness does.** Apple's advice: make at
  least one foreground element white ("usually the most prominent or
  recognizable part") and map the others to greys, with as much range
  between darks and highlights as possible. An icon must be recognisable by
  shape alone.
- **Fill, opacity and blend mode can differ per appearance**; glass and
  layout settings apply to all. So the default, dark and mono versions may
  each have their own colours and background, but the shapes should stay the
  same ("keep your icon's features consistent across appearances").
- **The background is a fill set in Icon Composer** (solid or gradient), not
  an exported layer. "Automatic" uses Apple's system light background for
  default and system dark for dark. Apple recommends its system backgrounds
  for contrast under the new glass, and says to watch luminance in mono if
  using a custom one.
- **Filled, overlapping shapes are preferred to outlines.** The guidelines
  show a filled disc as the example to follow and an outlined ring as the
  one to avoid, and warn against thin lines. This also argues for the discs
  over the earlier ring.
- **Layers**: flat, opaque SVGs on a 1024 px canvas (1088 px for watchOS),
  no mask, no shadows or blurs baked in; at most four groups. Glass,
  specular highlight, translucency and shadow are added in Icon Composer.
- **watchOS** has no appearances, masks the icon to a circle, and Apple says
  to avoid a black background there: lighten the ink for the Watch.

What follows for this icon:

- Two layers, `disc` and `dot`, each one colour, so each appearance needs
  only two fills changed.
- The gap cannot be an ink-coloured circle between the layers: the
  background changes per appearance and is see-through in clear mode, where
  an ink circle would show as a dark blob. The disc's SVG path has to have
  the bite subtracted.
- Mono annotation: amber's own grey is light (`#c2c2c2`), close to white, so
  left to the automatic conversion the two bubbles nearly merge. Set the dot
  to white and the disc to a clearly darker grey (or the reverse for the
  off-white-disc version). The all-amber version has one tone in every
  appearance and depends on the gap alone, which makes it the most
  predictable under tinting and the least distinctive.
- Amber against off-white is only 1.56:1. The two bubbles cannot simply
  overlap without a gap: wherever the icon is drawn flat (the PWA, older
  OS versions), the dot's edge inside the disc would almost disappear.
- The composition fits the PWA's maskable safe zone (a centred circle of
  40% radius) and the Watch's circular mask without changes.

## Associations to avoid

Each of these was noticed by the owner on a real draft and steered the
design:

- **Power button**: a ring with a gap and something in the gap.
- **A ring as an object** (jewellery, and a sex toy with the same outline):
  a thin even band with a small blob on its edge.
- **Pac-Man**: a disc with a bite and a small dot in front of the bite. It
  was strongest where the dot was fainter than the disc (dark disc and pale
  dot on an amber background). Mitigations, both in the chosen design: the
  dot is brighter than the disc, and the gap is narrow (8 px, was 16) so the
  cut hugs the dot instead of reading as an open mouth.

## Options considered

In order, all drawn on design sheets (links below):

1. **Ring and dot** (the shipped icon) and variants: thicker, a gap in the
   ring, an orbit. Returned to twice; dropped for the power button and ring
   associations.
2. **Q of T**: the ring with a T-shaped tail, so the mark spelled Q, o and
   T. Explored over three rounds, then dropped: "looks a bit silly".
3. **Two go-wide rounds** unrelated to the ring (cursor, quote marks,
   asterisk, tally, pilcrow, folded page and others). None liked.
4. **Strings and loops**: one line tied into a Q-shaped loop, after a nod to
   string theory. None liked.
5. **Heavy ring, rounded square, centre dot**: alternatives that avoid the
   ring association. Passed over for the disc.
6. **Solid disc with a dot**: chosen. Variants turned down: a detached dot
   and three bubbles (lose the Q), a much larger dot, a dot behind the disc,
   a hollow dot, and paper or amber backgrounds.
7. **The last three**, all liked: amber disc with off-white dot (N1,
   chosen), off-white disc with amber dot (N2: the dot is the fainter
   element, the condition that brought out Pac-Man) and both amber (N3: one
   tone, so the same in every appearance but the least distinctive). A
   version with no gap, the dot laid over the disc, was turned down: amber
   against off-white is 1.56:1, so the dot's edge nearly disappears.

Colour research from the same exploration, in brief: claims that a colour
causes a feeling are weakly supported (Gnambs 2020 is a meta-analysis
finding small effects); what is reliable is lightness contrast, staying
readable with colour-vision deficiency (amber against a blue-black is on the
safe axis), one small accent on a neutral base, and looking different from
neighbouring icons. Not re-verified here.

## Follow-ups

- #105: build the icon (the two SVG layers, Icon Composer, the Watch's
  lighter background, the PWA's icon files, CLAUDE.md).
- #106: a side finding, the PWA's light-theme accent `#c98a12` is 2.8:1 on
  paper, too faint for the link-style buttons it is used for.

## Sources

- Apple, [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
  (read 2026-11-19).
- Apple, [Human Interface Guidelines: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
  (change log to 2026-10-28).
- Apple, [Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/)
  (WWDC25 session 361), from a machine summary of the transcript.
- Apple, [Icon Composer for beginners group lab](https://developer.apple.com/videos/play/wwdc2026/8012/)
  (WWDC26), from a machine summary of the transcript; quotes may be
  inexact.
- Contrast ratios are WCAG 2 relative-luminance ratios computed from the hex
  values.
- Design sheets (private to the owner's Claude account):
  [first explorations](https://claude.ai/artifact/SrJouNpHSVjF2bmpKaGWSA),
  [go-wide ideas](https://claude.ai/artifact/HMfnKabNoZA1ZfpZELHUc8),
  [ring and dot](https://claude.ai/artifact/FLuX8nkuq37hM9Kf8An5kg),
  [thought bubble Q](https://claude.ai/artifact/DHr6zdnruUEDVRuB84uhPv).
