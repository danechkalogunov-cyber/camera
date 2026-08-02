# Acceptance — R1 on real hardware

The one test nothing in this repository can run. CI compiles every line and executes 2 709 tests
against fake sockets, which by construction answer what they were told to; a camera does not.

`docs/API_CONTRACT.md` §8.2 states the gate in one sentence:

> One factory-default-IP Hikvision camera on the LAN; launch the app; type only the password; reach
> a **visible moving picture within 10 seconds**.

Everything below exists to make that sentence falsifiable.

---

## 0. Before you start

| | |
|---|---|
| **Hardware** | One Hikvision camera (or OEM: Annke, LTS, TruVision), powered, on the same LAN as the Mac |
| **Credentials** | The camera's `admin` password. If the camera has never been activated, activate it in SADP first — Vigil does not activate cameras |
| **Mac** | macOS 14 or later, Apple silicon or Intel |
| **Build** | `Scripts/build-app.sh`, then `open dist/Vigil.app` |

Read the build script's own output before launching. It prints one of two things about multicast,
and which one decides what §3 should show:

```
[note] no provisioning profile, so the managed multicast entitlement cannot be honoured
[note] using Resources/Vigil-nomulticast.entitlements — discovery degrades to a unicast sweep
```

That is the **expected** message for a local build. It is not a failure, and §3 has a separate pass
condition for it.

⚠️ If the app is signed with `Vigil.entitlements` (multicast present) and **no** embedded
provisioning profile, macOS will not launch it at all — `Launchd job spawn failed`, POSIX 163. The
build script already prevents this; if you see that error, the script was bypassed.

---

## 1. The gate: launch → picture, password only

The test the contract actually names. Run it first, before anything else, on a Mac that has never
run Vigil (or after deleting `~/Library/Application Support/Vigil`), because "no configuration" is
half the requirement.

1. `open dist/Vigil.app`
2. Start a stopwatch as the window appears.
3. Type **only the password**. Do not type an address.
4. Press Return.

**Pass:** a moving picture, within **10 seconds** of the window appearing.

**Record:** the elapsed time, the camera model, its firmware version, and whether the address was
found by the scan or was already in the form.

> **What happens between steps 1 and 3.** With no remembered camera and an empty address field,
> Vigil starts a silent scan the moment the window appears — no sheet, no list — and fills the
> address in as soon as one confident Hikvision camera answers. That is the mechanism R1 rests on,
> and it is why the stopwatch starts at the window and not at the first keystroke: the search is
> running while you are reading the password prompt.
>
> It never overwrites something you are typing. If you start entering an address and the scan
> answers a second later, your text wins and the scan stops.
>
> ⚠️ **This is the step most likely to fail first, and it has never run against a camera.** If the
> address does not appear within a few seconds, that is the finding — record it, then press
> `Find Cameras…` and continue from §3, marking §1 as **R1-partial**.

---

## 2. What "a visible moving picture" means

Not a spinner, not a first frame, not a still. The pass condition is motion the eye can see: wave a
hand in front of the lens and the picture must follow.

Three near-misses that are **failures**, recorded separately because each has a different cause:

| Symptom | What it means |
|---|---|
| One frame, then frozen | Decode succeeded, the stream stalled. Capture the log — `recoverStalledPicture` should have fired |
| Grey/green blocks that never resolve | Missing parameter sets: the decoder started before SPS/PPS. Capture the first 200 log lines |
| Picture appears, then goes black after seconds | Almost always the black-flash rule being violated, or the connection dropping without the offline overlay |

---

## 3. Discovery on a live network

Never run outside CI before this document existed. Three separate questions — record each.

### 3.1 Does anything answer?

Press **Find Cameras…** on the connect form.

* **With multicast** (a provisioning profile was embedded): cameras on *other* subnets should also
  appear, including a factory-fresh camera still on `192.168.1.64` while the Mac is on a different
  network. Expect results in roughly 1.5 s on a `/24`.
* **Without multicast** (the ordinary local build): the sheet says so *before* the run —
  "This build cannot use multicast, so only a direct sweep of this subnet runs." Only cameras on
  this subnet answer, in roughly 4–6 s. **This is a pass**, not a failure.

**Fail** if the sheet stays empty with a camera on the same subnet, or if it shows no notice while
the build has no multicast entitlement.

### 3.2 Is the row right?

For each row, check the address against the camera's own settings, and check the label:

* no label — Vigil spoke ISAPI to it, so it is a Hikvision camera;
* **not ISAPI** — something answered on the network but not as a Hikvision camera. Vigil will still
  try RTSP;
* **possible** — confidence below 30. Worth trying; not a claim.

**Fail** if a row shows the wrong address, or claims ISAPI for a device that then refuses `/ISAPI/`.

### 3.3 Does closing the sheet silence the network?

The only place the socket teardown is real. Start a scan and close the sheet **while it is still
running**.

Run `sudo tcpdump -i any -n 'udp port 37020 or udp port 3702'` alongside. Traffic must stop within
about 50 ms of the sheet closing.

**Fail** if probes keep going after the sheet is gone. That is the defect fixed in `VigilDiscovery`
this cycle — `.finished` used to be published before the sockets closed, and a channel that finished
opening after the run ended was never closed at all. Both have tests, but only a real socket proves
it.

### 3.4 What discovery must never do

* It must **never** send a credential. `discoveryCoordinatorSendsNoCredentialsAnywhere` asserts it,
  and a packet capture is the independent check.
* Choosing a row must **only** fill in the address. If Vigil connects without you typing a password,
  that is a failure severe enough to stop the run.

### 3.5 Zero egress — what it means now that a scan runs at launch

`FEATURES.md` §20.3 says "no telemetry", and enforces it with "a test asserting **zero** network
connections with no cameras configured". That sentence was written before Vigil scanned on launch,
and taken literally it is now false: with no cameras configured, Vigil opens LAN sockets the moment
the window appears. R1 requires exactly that.

⚠️ Read as intent, not as wording, the requirement is unchanged and this build still meets it. The
claim §20.3 exists to make is **no traffic to the internet, ever** — no analytics, no crash
reporter, no usage ping, no update check. `HostPolicy` makes it a code property rather than a
promise: `.publicInternet` and `.invalid` are refused before a socket is created, in
`VigilTransport`, `VigilISAPI` and `VigilDiscovery` alike.

So the check is not "zero packets", it is "zero packets that leave the LAN":

```
sudo tcpdump -i any -n 'not net 10.0.0.0/8 and not net 172.16.0.0/12 \
    and not net 192.168.0.0/16 and not net 169.254.0.0/16 \
    and not net 224.0.0.0/4 and not host 127.0.0.1'
```

Launch Vigil with no cameras configured, let the scan run to its deadline, and leave it sitting on
the connect form for ten minutes.

**Pass:** nothing from Vigil. DNS for something else on the Mac is not Vigil's traffic — check the
process with `lsof -i` before recording a failure.

**Fail:** any packet at all. That is a defect regardless of where it went or what it carried, and it
is the one failure in this document that should stop a release rather than be filed.

*Wording to fix in the specs, not in the code: §20.3 and API_CONTRACT §8.2 should say "zero egress
beyond the local network" rather than "zero network connections". The code is right; the sentence
predates the feature.*

---

## 4. Recording

Vigil must write nothing to the Mac beyond recordings deliberately saved.

1. Run for ten minutes without pressing record.
2. `find ~/Movies ~/Pictures ~/Library/Application\ Support/Vigil -newermt '-10 minutes'`

**Pass:** nothing but the app's own preferences. **Fail:** any clip, snapshot or cache written
without being asked for.

Then press ⌘R, wait, press ⌘R again.

**Pass:** exactly one file, playable in QuickTime, of about the expected duration, with no `.partial`
left behind.

**Fail:** a clip that vanishes from the library after recording — that is VG-REC-0002, the recovery
scan renaming a segment out from under the recorder. Fixed, and this is where it shows up if the fix
is wrong.

---

## 5. When it fails

Do not summarise. Capture, in this order:

1. `Console.app`, filtered to subsystem `com.vigil.app`, from launch to failure.
2. The exact wall-clock time of the failure, so the log can be aligned to it.
3. The camera's model and firmware, from its own web UI.
4. For anything network-shaped: `tcpdump -i any -n -w vigil.pcap host <camera-ip>`.

A failure with a log is a defect. A failure without one is a rumour — this project has already spent
a full build cycle on a symptom that was reported without evidence.

---

## 6. Results

Append a row per run. Never edit a previous one: a test that passed in June and fails in July is two
facts, not one.

| Date | Build | Camera / firmware | §1 time | §2 | §3 | §4 | Notes |
|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | *No run yet. Every line above is untested procedure, not a record of anything that happened.* |
