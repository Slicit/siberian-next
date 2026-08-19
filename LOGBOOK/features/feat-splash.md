---
status: shipped
branch: feat-splash
---

# A splash somebody chose, and an animated one on Android

## Intent

The first thing anybody sees of an app is the screen it shows before it has
drawn anything, and until now that was a colour. An operator, or whoever runs a
domain, should be able to put their own artwork there.

Square artwork, because the screen it lands on is never the shape you designed
for. Centred and contained rather than cropped, and with the part that is
guaranteed to survive stated rather than left to be discovered on a device that
crops it.

Android can also animate one. Nothing else can.

Out of scope for this feature:

- An animated splash anywhere but Android. iOS has no equivalent, and pretending
  otherwise would mean shipping something that silently does nothing.
- Generating the artwork. This takes a file; it does not make one.
- Per-platform artwork. One square image serves both, which is the point of
  requiring a square.

## Plan

1. ~~Splash fields on the app, and validation that refuses what cannot work.~~
2. ~~Uploads through the Mobile service into Storage, where the quota already governs them.~~
3. ~~The builder fetches assets by kind, holding no credential of its own.~~
4. ~~The Android animation applied after prebuild, where the generated theme is.~~
5. ~~Both uploads in the Backoffice and on the product side.~~

## Decisions

### 2026-08-19

- **Decision:** the image must be square, and `resizeMode` is `contain`.
- **Why:** the artwork is square and no screen is. Covering would crop the sides off a logo on a tall phone and the top off it on a tablet. Contained, the whole square is always visible and the background colour fills what is left, which is what "centred with safe zones" means once it has to survive contact with a device.
- **Impact:** a rectangle is refused with its own dimensions in the message rather than accepted and quietly cropped. 2500 is the recommended size and a smaller square is a warning, not a refusal, because a square scales and a rectangle does not become square.

- **Decision:** the safe zone is stated as the centre 66 percent, in the interface, next to the field.
- **Why:** Android masks the splash icon to a circle. Artwork that fills its canvas loses its corners, and the person who finds that out is holding a phone rather than reading a spec.
- **Impact:** the upload answers with the pixel figure for the image that was actually sent, so it is arithmetic somebody does not have to do.

- **Decision:** an animation is an AnimatedVectorDrawable, and a GIF is refused by name.
- **Why:** the Android splash screen API animates exactly one thing. A GIF is what everybody reaches for first, and "unsupported file" would send them looking for a converter rather than telling them the format does not exist on that surface.
- **Impact:** the refusal says what Android does animate. The duration is clamped to one second, because the platform stops it there and storing three would be storing a promise it does not keep.

- **Decision:** the assets go to Storage, and the builder is handed bytes rather than a path.
- **Why:** the builder runs third-party module code and holds no Storage credential, which was decided when it was built and is not worth giving up for an image. Putting the artwork in Storage also means the quotas an operator already set govern it.
- **Impact:** `GET /internal/builds/:id/asset/:kind` streams one asset for a build the caller has claimed. It never learns a path, a bucket, or which domain the file sits under.

## Outcome

Shipped 2026-08-19. Both uploads are on the Backoffice page and the product-side
page, and both refuse what cannot work while the person who chose the file is
still looking at the screen rather than twenty minutes later in a Gradle log:
a rectangle by its dimensions, an undersized square by its size, a GIF by its
format, and a three second duration by clamping it to the one second Android
allows.

What is verified is that the build applies them: `splash.png` in the workspace,
the drawable written into `res/drawable`, and the two theme attributes in the
generated `styles.xml`. How it looks on a phone is not something this box can
answer, and nothing here claims otherwise.
