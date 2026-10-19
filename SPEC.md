# PitchNeedleBar — specification

**Tagline:** A menu bar chromatic tuner that listens through your mic and shows how sharp or flat each note is.

**Category:** Audio

**Inspired by (paid):** ChromTuner ($6.99 one-time)

**Frameworks:** SwiftUI, AppKit, AVFoundation, Accelerate, CoreAudio, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: ChromTuner is a menu bar chromatic tuner for macOS sold outside the App Store at 6.99 dollars, runs fully offline and has no subscription. Paid tuners such as Chromatic Instrument Tuner Pro at 5.99 dollars and iChromatic Strobe Tuner at 4.99 dollars sit in the Mac App Store, and musicians keep recommending a quick desktop tuner for guitars, violins and voices, so demand is steady. Our free version reproduces the core tuner in one small window.

Feature set: Listen to the chosen microphone, detect the fundamental pitch in real time, display the nearest note name with octave, show the deviation in cents on a needle meter, and show the detected frequency in hertz. Allow a reference pitch from 415 to 466 hertz with 440 as default. Offer a transposition field for brass and reed instruments. Add a hold button to freeze the reading, and a reference tone generator that plays the selected note so users can tune by ear. Target roughly 450 lines.

UI spec: A MenuBarExtra with window style around 280 by 260 points. The top shows the large note name, the octave, and the frequency. The center shows a semicircular needle gauge that turns green within 5 cents. Below sit a device picker, the reference pitch stepper, and a transposition picker. A small play button toggles the reference tone. The idle state, when no clear pitch is present, shows dashes and the text Play a note. The menu bar icon is a tuning fork and turns green while in tune. Settings include launch at login, the input device, a sensitivity slider for the noise gate, and a toggle to keep listening only while the popover is open, which is on by default to save battery.

Technical approach: Use AVAudioEngine with an input node tap of 4096 frames at the device sample rate. Compute the pitch by autocorrelation or the normalized square difference method, implemented with Accelerate vDSP routines for the correlation sums, then apply parabolic interpolation around the best lag to get sub-sample accuracy. Apply a root mean square gate so quiet room noise is ignored, and a median filter over the last five readings to steady the needle. Convert frequency to note number using twelve times the base two logarithm of frequency over reference, then derive cents. The reference tone uses an AVAudioSourceNode that renders a sine wave. Microphone permission: add the microphone usage description, request through AVCaptureDevice authorization on first open, and show a blocked view with a button to the Privacy settings pane if denied. Start the engine when the popover appears and stop it when it closes. Persist settings with AppStorage. Launch at login uses SMAppService.

Edge cases and error handling: If the input device disappears, fall back to the system default and show a notice. If the sample rate is unusual, size the buffer proportionally. Prevent feedback by muting the reference tone while the mic listens, or warn if no headphones are in use. Handle octave errors by preferring the lowest lag with a strong peak. Clamp the reference pitch to the allowed range and show a clear message when permission is denied.
