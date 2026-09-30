---
layout: doc
title: Sloppies
---

# Sloppies

Sloppies are geometric agent companions shared by the Dashboard and the Apple client. Each bot is one smooth body with two eyes and no legs, separate head or accessories.

## Appearance

| Body | Eyes |
|---|---|
| Circle | Rounded vertical pills |
| Triangle | Circles |
| Diamond | Rounded diamonds |
| Square | Rounded squares |

The transparent PNGs contain only grayscale bodies. Separate eyes provide the expressions. Colors are picked independently from eight palettes when an agent is created: mint, violet, coral, amber, sky, rose, lime or graphite. The choice is saved in `pet.visual.paletteId`, so the same agent has the same color across screens and restarts. Eye colors are paired with body colors for contrast.

The artwork is generated during development. There is no avatar prompt, model picker or regeneration action. Shape assignment uses UTF-8 FNV-1a with a 32-bit seed, modulo the ordered catalog above. Renaming an agent keeps its appearance.

The notch follows the pointer, blinks, and expresses happiness, surprise, anger, error, thinking and needs-input through the eyes. Dashboard Pet previews also follow the pointer, blink and react to clicks. List avatars remain static. Reduced Motion disables cyclic blinking and gaze movement.

## Existing pets

On read, Core replaces legacy pixel sprites and generated avatar briefs with the new PNG catalog. Existing pet ID, genome, rarity, base stats, current stats and XP are preserved. Existing XP stages keep the same PNG appearance.

The retired `POST /v1/pets/generate` endpoint returns HTTP 410 with `pet_generation_removed`. The compatibility status endpoint advertises generation as unavailable. Old pet drafts cannot be attached to newly created agents.

## Statistics

Non-system agents retain their five progression stats: Wisdom, Debugging, Patience, Snark and Chaos. Direct chats, linked channels, heartbeats and automated runs continue to contribute through the existing progression engine. Its daily caps and source weights are unchanged.

The Overview card shows the companion, XP progress and current/base stat bars. System agents use bot avatars in lists without acquiring a progression pet.

## Artwork maintenance

The generation prompts and asset workflow are documented in `ClientNative/docs/bot-assets.md`. Copy the final PNGs into both `ClientNative/Sources/SloppyClientUI/Resources/Bots` and `Dashboard/public/pets/bots`. The asset test verifies byte-for-byte equality and the identity fixtures across clients.

## Related

- [Runtime](/agents/runtime)
- [Channels](/channels/about)
