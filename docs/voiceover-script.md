# Kineon voiceover script (4:00)

About 632 words. Read at about 155 words a minute. Each block is timed to its scene in the walkthrough page; play it while recording and follow the highlighted words.

Tone: warm, unhurried and plain. Say "Kineon" the way the team says it, "XG Boost" as letters then the word, "hertz" in full, "crore" as a word, and the doses as "eight A M". Breathe at each scene change. Pause for a beat after "One visit sees one moment" and after "He doesn't have to sit still for us to measure".

## 0:00–0:17 · The problem

Every few months, a person with Parkinson's sees their neurologist for a short visit. But tremor rises and falls all day: around each dose, with stress, with sleep, with a cup of chai. One visit sees one moment. So medicine gets adjusted almost blind.

*On screen:* A day of tremor from 6 AM to 10 PM. One 15-minute clinic slot is highlighted.

## 0:17–0:33 · The need

In India that gap is wider. Estimates of Parkinson's patients here range from half a million to seven million, and cases worldwide are expected to pass twenty-five million by 2050. Yet India has only a few thousand neurologists, mostly in big cities.

*On screen:* Four figures appear one by one, each with its source.

## 0:33–0:52 · The idea

Kineon works on the phone or watch a patient already owns, recording motion fifty times a second, all day. NeuroSense checks the signal, and an XGBoost model decides whether each movement is tremor. NeuroTwin learns each patient's own normal. NeuroLearn sends uncertain cases to neurologists, so it improves with every clinic.

*On screen:* The pipeline lights up step by step: device, NeuroSense, NeuroTwin, NeuroLearn, then the trust layer underneath.

## 0:52–1:11 · Scenario 1

Here's how it works. Our patient is resting on the sofa. The watch sees a narrow, steady rhythm at about five and a half hertz. The model is confident it's tremor, so the reading counts, with a score and a confidence band that tells the doctor how sure we are.

*On screen:* Live trace and spectrum. The peak sits at 5.4 Hz in the tremor band; the checks turn green; the classifier shows P(tremor) 0.96; the watch shows a score with its band.

## 1:11–1:20 · Scenario 2

When he holds a cup, a faster tremor appears, around seven hertz. Kineon labels it action tremor, an essential-tremor-like pattern, and counts it too.

*On screen:* The peak moves to about 7 Hz. Still counted.

## 1:20–1:40 · Scenario 3

He doesn't have to sit still for us to measure. Now he brushes his teeth. His wrist moves hard, and a simple tracker would log severe tremor. Our XGBoost model looks at the shape of the movement and classes it as everyday activity, not tremor. So it isn't counted, and his average stays honest.

*On screen:* Big, messy trace with a wide, drifting spectrum. The classifier shows P(tremor) 0.07. The watch says the movement was not counted.

## 1:40–1:52 · Scenario 4

He walks to the door. Plain walking is classed as not tremor. But when a tremor rides on top of his steps, the model picks it out, and that reading counts.

*On screen:* Plain walking first: a tall step peak near 1.8 Hz, not counted. Then the same walk with a 5.4 Hz tremor on top: counted.

## 1:52–2:12 · Scenario 5

One thing still comes first: signal quality. If the watch is left on a table, the trace goes flat, and the app says 'not enough data', never zero, because zero would tell the doctor the tremor has gone. If a loose strap knocks against the wrist, the spikes are caught as noise.

*On screen:* A flat line, then sharp spikes. The signal check fails first, then the noise check.

## 2:12–2:24 · Phone test

Most Indian patients don't own a smartwatch. So there's a thirty-second phone test with the arm held out, plus spiral and tapping tests on the screen. The same engine scores them.

*On screen:* A phone counts down from 30 with the arm outstretched, then shows a score.

## 2:24–2:43 · Over time

Each good reading feeds a personal baseline. One tap logs a dose, with tags for caffeine, stress or poor sleep. Over two weeks, the doctor sees tremor against dose times. We describe, never conclude: 'tremor was lower in the two hours after the eight A M dose.' No dose advice, ever.

*On screen:* The last 3 days of a 14-day illustrative patient. Dose lines, a dashed baseline, withheld readings as grey ticks.

## 2:43–2:57 · Calm Mode

If tremor climbs well above his own baseline, Calm Mode offers simple steps: rest the forearm, hold the cup with both hands, and breathe with taps on the wrist, with spoken guidance in Hindi, Kannada or Tamil.

*On screen:* A breathing circle: one tap in, two taps out. The guidance switches between English, Hindi, Kannada and Tamil.

## 2:57–3:12 · For the doctor

Before the visit, the doctor gets a one-page report, and the family can hear a spoken summary in their language. Sharing needs consent, withdrawn in one tap. Every report is signed with quantum-safe cryptography, so anyone can check it.

*On screen:* The report with a spoken summary, its ML-DSA signature and Verify check, the ABHA link, the consent switch, and the review queue. Try turning consent off.

## 3:12–3:26 · Families & devices

Families stay in the loop with a weekly update, and an alert if things get worse. And because the software works with any device, tomorrow Grandpa keeps wearing his old HMT watch. We just change the strap.

*On screen:* A caregiver's weekly update, then the TremorStrap pod and smart kada.

## 3:26–3:40 · Feasibility

Is this feasible? It runs on the Apple Watch and iPhone today, with no new hardware. Every verified episode builds India's first neurologist-verified movement dataset. And cloud costs are about thirty to sixty rupees per patient a month.

*On screen:* Three cards: no new hardware, learns from clinics, the dataset. Then a bar comparing cost with revenue per patient.

## 3:40–3:53 · Market

Clinics pay four to six hundred rupees per patient a month. Three hundred clinics with forty patients each is about seven crore rupees a year. We start with two or three clinics in Bengaluru.

*On screen:* The bottom-up sum, a competitor table, then the roadmap.

## 3:53–4:00 · Close

Kineon doesn't diagnose or treat. It gives your neurologist better data, and the doctor makes every decision.

*On screen:* The closing line on a clean screen.
