# Setup Selection Bugfix

## Symptom

On Step 1, these controls could open but their items were not tappable for a long time:

- `Audio language`
- `Subtitle 1`
- `Subtitle 2`
- top-right settings button

Sometimes they became tappable only after waiting around 30 seconds.

## Why This Happened

There were two layers to the problem.

### 1. Step 1 became much more state-heavy after language caching was added

The regression window was the Step 1 cache change in commit `1defaf3`.

That change improved the empty-language-list problem by restoring cached language data early, but it also increased how often Step 1 updated its state while the screen was visible:

- cached speech locales were applied on appear
- cached subtitle targets were applied on appear and on later state changes
- subtitle selections were repeatedly re-synced from bindings
- subtitle target refreshes were triggered again when:
  - audio language changed
  - translation provider changed
  - scene became active
- asset readiness checks were also re-run from the same screen

This created a lot more activity on the Setup screen than older versions had.

### 2. The critical interaction path depended on `Menu`

Even after reducing some of that churn, the actual failing controls still had one thing in common:

- the Step 1 language selectors used `Menu` / `.pickerStyle(.menu)`
- the top-right settings button also used `Menu`

So the bug was not only "language loading is expensive".  
The real user-facing failure was that the Setup screen depended on a `Menu` interaction path that became unreliable in this layout and lifecycle.

In practice:

- the menu could render
- items could be visible
- but item taps were unreliable or delayed

That is why earlier attempts that only optimized async work improved the screen, but did not fully fix the bug.

## Why Older Versions Felt Better

Older versions had less Setup-screen state churn, so the `Menu` problem was harder to trigger or easier to miss.

After the language-cache change, Step 1 did more immediate state restoration and more follow-up refresh work, so the weak point in the `Menu` path became obvious.

## What Fixed It

The real fix was to remove `Menu` from the critical path.

### Changes made

#### `SubStamp/UI/SetupView.swift`

Replaced Step 1 selectors with sheet-based selection screens:

- `Audio language`
- `Subtitle 1`
- `Subtitle 2`

These now open a normal SwiftUI sheet with a list of items instead of using `Menu`.

#### `SubStamp/UI/Components/SettingsMenuButton.swift`

Replaced the top-right gear `Menu` with a sheet-based settings panel.

That panel now contains:

- display language options
- appearance options
- upgrade entry when needed

### Why this works

Normal sheet + list interaction is much more stable here than `Menu`.

Instead of trying to keep fighting the dropdown path, the fix moves selection onto:

- standard tap targets
- standard list rows
- standard sheet presentation

That removes the exact interaction path that was failing for users.

## Additional Supporting Improvements Kept

These changes were still worth keeping because they reduce unnecessary Setup-screen work:

### `SubStamp/Domain/LanguageSelectionModels.swift`

- heavy subtitle-target computation is no longer kept on the main UI path

### `SubStamp/UI/SetupView.swift`

- subtitle-target refreshes are cancellable
- stale async results are ignored
- asset checks are throttled instead of being stacked repeatedly

These changes help responsiveness, but they were not sufficient on their own.  
The full fix required replacing `Menu` usage for the affected controls.

## Final Conclusion

The bug existed because the Setup screen had become more state-active, and the controls most affected by that screen state all depended on `Menu`.

The successful fix was not just "optimize loading".  
The successful fix was:

1. reduce unnecessary async churn
2. remove `Menu` from the affected Setup interactions
3. replace those interactions with sheet-based selectors

That is why the issue is now fixed in a durable way instead of only becoming less frequent.
