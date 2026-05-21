# Cable Guide Blank Grid — Investigation Log

## Symptom
Add Show wizard step 2 shows the channel column (left side) correctly but the scrollable grid area (right side) is completely black. 106 channels load, entries exist (34 for ch 2.1, etc.), but nothing renders in the grid.

## What We Know
- Data is correct: 106 channels, 2600+ entries, verified in guide log
- Time window filtering is correct: entries pass `endDate > displayStart && startDate < displayEnd`
- The channel column (`channelColumnFixed`) renders fine from the same `allChannels` array
- The `[106 ch]` counter shows the data reaches AddShowView

## Attempts

### Attempt 1: LazyVStack → VStack
**Hypothesis**: `LazyVStack(pinnedViews: .sectionHeaders)` inside `ScrollView([.horizontal, .vertical])` 
doesn't render because lazy row visibility can't be computed for bidirectional scrolling.

**Change**: Replaced `LazyVStack(spacing: 0, pinnedViews: .sectionHeaders)` + `Section` with
plain `VStack(spacing: 0)`. `timeSlotsHeader` moved from Section header to first VStack item.

**Result**: No change — grid still blank.

**Conclusion**: LazyVStack was not the issue. VStack still doesn't render content.

---

## Next Steps / Hypotheses Being Tested
- [ ] Hypothesis: ScrollView has zero height inside HStack inside GeometryReader → add diagnostic colors
- [ ] Hypothesis: `.frame(width: totalW)` on the VStack is collapsing its height to 0
- [ ] Hypothesis: GeometryReader + VStack height calculation issue causing CableGuideView to get zero height
- [ ] Hypothesis: `onScrollGeometryChange` modifier crashing the ScrollView render
