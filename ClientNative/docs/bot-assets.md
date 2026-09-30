# Bundled bot artwork

Generated with the built-in imagegen tool, using https://x.ai/bot as the visual reference.
The four transparent grayscale body PNGs have no eyes. They live in `Sources/SloppyClientUI/Resources/Bots` and are copied byte-for-byte to `Dashboard/public/pets/bots`.
Artwork is generated during development. Runtime draws separate eyes and applies a cached tint to the PNG body. The app never calls a model to create an avatar.
Identity uses UTF-8 FNV-1a (32-bit, offset 2166136261, multiplier 16777619), modulo the ordered catalog: circle, triangle, diamond, square. Core, SwiftUI, SpriteKit and Dashboard use the same mapping. Changing an agent's display name does not change its bot. Shape uses the ID; color is independently picked from eight palettes using the random genome at creation and persisted as `pet.visual.paletteId`. Existing palettes are retained; older records get a stable fallback from their stored genome.
Legacy pet artwork is replaced on read; pet ID, genome, statistics and XP are preserved. XP stages keep the same artwork. The retired generation endpoint responds with HTTP 410.

## Generation prompts

### circle

Use case: stylized-concept. Asset type: production PNG agent avatar for Sloppy app, also animated desktop pet. Create ONE minimalist friendly geometric bot: a circle body in mint teal with two cream-white slim rounded vertical pill eyes. Body silhouette is exactly the named geometric shape, with generously rounded corners for polygonal shapes. The body and face are ONE shape, no separate head. Front facing, slight gentle tilt of eyes, eyes centered in upper middle. Inspired by the clean simple round bots of x.ai/bot: bold smooth silhouette and only two eyes. Very subtle soft matte volume and gentle tonal shading, crisp polished anti-aliased edges, mostly flat color, no outlines. Occupies 76% of a square canvas, perfectly centered, ample transparent padding. Genuine transparent background, no floor, no cast shadow outside silhouette. No legs, feet, arms, hands, mouth, nose, ears, antenna, accessories, symbols, text, logos, watermark, pixel art, grids, checkerboard artwork or extra characters. PNG with alpha.

### triangle

Use case: stylized-concept. Asset type: production PNG agent avatar for Sloppy app, also animated desktop pet. Create ONE minimalist friendly geometric bot: a triangle body in soft periwinkle violet with two cream-white small rounded circular eyes. Body silhouette is exactly the named geometric shape, with generously rounded corners for polygonal shapes. The body and face are ONE shape, no separate head. Front facing, slight gentle tilt of eyes, eyes centered in upper middle. Inspired by the clean simple round bots of x.ai/bot: bold smooth silhouette and only two eyes. Very subtle soft matte volume and gentle tonal shading, crisp polished anti-aliased edges, mostly flat color, no outlines. Occupies 76% of a square canvas, perfectly centered, ample transparent padding. Genuine transparent background, no floor, no cast shadow outside silhouette. No legs, feet, arms, hands, mouth, nose, ears, antenna, accessories, symbols, text, logos, watermark, pixel art, grids, checkerboard artwork or extra characters. PNG with alpha.

### diamond

Use case: stylized-concept. Asset type: production PNG agent avatar for Sloppy app, also animated desktop pet. Create ONE minimalist friendly geometric bot: a diamond body in warm coral orange with two cream-white softly rounded diamond eyes. Body silhouette is exactly the named geometric shape, with generously rounded corners for polygonal shapes. The body and face are ONE shape, no separate head. Front facing, slight gentle tilt of eyes, eyes centered in upper middle. Inspired by the clean simple round bots of x.ai/bot: bold smooth silhouette and only two eyes. Very subtle soft matte volume and gentle tonal shading, crisp polished anti-aliased edges, mostly flat color, no outlines. Occupies 76% of a square canvas, perfectly centered, ample transparent padding. Genuine transparent background, no floor, no cast shadow outside silhouette. No legs, feet, arms, hands, mouth, nose, ears, antenna, accessories, symbols, text, logos, watermark, pixel art, grids, checkerboard artwork or extra characters. PNG with alpha.

### square

Use case: stylized-concept. Asset type: production PNG agent avatar for Sloppy app, also animated desktop pet. Create ONE minimalist friendly geometric bot: a square body in golden amber yellow with two cream-white softly rounded small square eyes. Body silhouette is exactly the named geometric shape, with generously rounded corners for polygonal shapes. The body and face are ONE shape, no separate head. Front facing, slight gentle tilt of eyes, eyes centered in upper middle. Inspired by the clean simple round bots of x.ai/bot: bold smooth silhouette and only two eyes. Very subtle soft matte volume and gentle tonal shading, crisp polished anti-aliased edges, mostly flat color, no outlines. Occupies 76% of a square canvas, perfectly centered, ample transparent padding. Genuine transparent background, no floor, no cast shadow outside silhouette. No legs, feet, arms, hands, mouth, nose, ears, antenna, accessories, symbols, text, logos, watermark, pixel art, grids, checkerboard artwork or extra characters. PNG with alpha.


## Body layer edit prompt

Built-in imagegen edited each original character PNG using this same prompt, with its original PNG attached:

Edit the attached Sloppy bot PNG into a reusable body layer. Remove both eyes completely and seamlessly fill their locations with the same body material. Recolor the whole body to neutral pearly light gray, with ONLY neutral grayscale shades and its subtle original soft shading. Keep the original geometric silhouette, exact canvas size, exact position, proportions and rounded corners unchanged. Preserve transparent alpha background and anti-aliased edges. One single body only: no face, no eyes, no mouth, no legs or feet, no accessories, no symbols, no text. This grayscale PNG will be color-multiplied at runtime and eyes will be drawn as a separate animated layer.

The palette catalog is mint, violet, coral, amber, sky, rose, lime and graphite. Eye colors are paired for contrast. Native uses cached 512px tinted bodies; Dashboard multiplies the original PNG with an SVG color matrix. Both use the same palette values.

## Eyes and emotions

The notch follows the cursor and blinks every 4.2 seconds. Pokes produce surprise, happy curved eyes, then an angry squint. Error uses drooping eyes; thinking uses an asymmetric squint and upward gaze; needs-input uses asymmetric eye sizes. Typed runtime state overrides playful reactions. Reduced Motion disables cyclic blinking and gaze motion, while preserving the facial state.

Dashboard Pet previews track the pointer, blink and react to clicks. List icons stay static to avoid animating every avatar. Native SwiftUI avatars draw the same separate eye shapes; the notch animates them in SpriteKit.
