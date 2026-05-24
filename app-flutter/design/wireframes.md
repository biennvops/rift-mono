# Wireframes

## Pairing Screen
- Fingerprint compare (8 groups of 4 chars)
- Approve / Reject buttons
- Timeout / expiry indicator
- Small help text explaining verification

## Trusted Devices List
- Rows with: device name, fingerprint (short), presence indicator, capability summary
- Context menu: Revoke / Block / Rename
- Search and sort by name / last-seen

## Event Log / Operation History
- List of events with `eventType`, `timestamp`, `severity`
- Filter by event type and search box
- Details pane showing event metadata (explicitly NOT clipboard content)

## Clipboard Transfer Status
- Offer list with `offerId`, `contentType`, `byteSize`, `sha256`, expires
- Per-offer action: Accept / Reject / Fetch progress
- Hash verification result and human-readable status
