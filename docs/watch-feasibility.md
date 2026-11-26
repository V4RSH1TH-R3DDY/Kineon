# Kineon on Apple Watch: what is feasible

Checked against the watchOS 27.2 / iOS 27.2 SDKs (Xcode 27.2), November 2026. "Built" means it is in the code and compiles; nothing has been tested on a real device yet.

| Feature (from the story and walkthrough) | Feasible on watch? | Status | How |
|---|---|---|---|
| Motion at 50 Hz | Yes | Built | CoreMotion device motion (gravity + user acceleration, in g) plus gyroscope |
| Live score while the wrist is down | Yes | Built | `HKWorkoutSession` keeps the app running; falls back to a 1-hour physical-therapy session, then to screen-on only |
| Measuring **all day** | Yes, but not live | Built | `CMSensorRecorder` records 50 Hz for 12 h at a time, kept 3 days. The app collects one 10 s window a minute in background refreshes. Data arrives minutes to hours late. A workout session all day would drain the battery |
| Heart rate | Yes, during live sessions | Built | `HKLiveWorkoutBuilder`. Not available from all-day recording |
| Brushing / walking not counted | Yes | Built (rules) | The backend scorer withholds voluntary movement |
| XGBoost "is this tremor?" model | Yes | Not built | Train in Python; run it on the server, or convert with coremltools to Core ML and run it on the watch |
| Loose strap → phone alert | Yes, inferred | Built | No public API reports strap fit or wrist detection. The phone infers it from repeated noisy or flat windows and sends a local notification |
| Watch buzz on a high reading | Yes | Built | Haptic plus a "Try Calm?" banner when a fresh score is clearly above the patient's usual |
| Calm Mode haptic breathing | Yes | Built | `WKInterfaceDevice` haptics, works offline |
| One-tap dose log | Yes | Built | Sent to the phone with guaranteed delivery |
| Watch works when the phone is away | Yes | Built | `transferUserInfo` queues windows; the phone also queues on disk if the server is down |
| Emergency contact sees live data | Not a watch limit | Not built | Needs a hosted server with sign-in, and push notifications (APNs needs the paid $99/yr Apple Developer Program) |
| Book the personal neurologist | Not a watch limit | Not built | App and server feature; real booking needs the clinic's system (e.g. ABDM) |
| Doctor downloads a signed chart | Not a watch feature | Built (backend and dashboard) | Ed25519-signed PDF and CSV, gated by consent |
| Voice guidance in Hindi, Kannada, Tamil | Yes | Partly built | Server speech; Tamil not added yet |
| Spiral and tapping tests | Phone yes; watch tapping only | Not built | The watch screen is too small for a spiral |

## Limits to plan around
- **Free Apple ID:** apps expire after 7 days and must be reinstalled from Xcode. There is a small limit on apps per device, and no push notifications. If HealthKit won't sign, the watch falls back automatically, but there is no heart rate.
- **Battery:** live sessions cost roughly as much as an indoor workout. Use them for minutes to an hour, and use all-day recording for the rest.
- **Background refresh:** watchOS decides when to wake the app (about every 30 minutes at best). Opening the app catches up straight away.
- **Network:** the backend has no sign-in, so it must stay on a trusted local network until auth is added.
