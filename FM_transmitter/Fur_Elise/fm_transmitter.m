%% ADALM PlutoSDR - FM Melody Transmitter
% Transmits Fur Elise as an FM signal — clearly recognizable on any FM radio
%
% Requirements:
%   - Communications Toolbox
%   - Communications Toolbox Support Package for Analog Devices ADALM-Pluto Radio
%   - ADALM PlutoSDR connected via USB

clc; clear; close all;

%% ============================================================
%  PARAMETERS
%% ============================================================

fc            = 90.1e6;    % Carrier frequency — quietest channel from scan
max_freq_dev  = 75e3;      % FM frequency deviation (75 kHz = broadcast standard)
fs_audio      = 200e3;     % Baseband sample rate
fs_pluto      = 2.8e6;     % PlutoSDR TX sample rate (must be integer multiple of fs_audio)
interp_factor = fs_pluto / fs_audio;  % = 14
tx_gain       = -10;       % Increased from -20 to -10 dB for stronger signal
pluto_uri     = 'ip:192.168.2.1';

%% ============================================================
%  BUILD FUR ELISE MELODY
%% ============================================================
% Note frequencies (Hz)
E5=659.25; Ds5=622.25; B4=493.88; D5=587.33; C5=523.25;
A4=440.00; C4=261.63; E4=329.63; A3=220.00; B3=246.94;
D4=293.66; Gs4=415.30; Bb4=466.16; F4=349.23; G4=392.00; R=0; % R=rest

% [frequency, duration_in_beats]  (1 beat = 0.25 sec at tempo below)
tempo_bps = 4;   % beats per second (quarter note speed)

score = [
    E5,1;  Ds5,1; E5,1;  Ds5,1; E5,1;  B4,1;  D5,1;  C5,1;
    A4,2;  R,1;   C4,1;  E4,1;  A4,1;
    B4,2;  R,1;   E4,1;  Gs4,1; B4,1;
    C5,2;  R,1;   E4,1;  E5,1;  Ds5,1;
    E5,1;  Ds5,1; E5,1;  B4,1;  D5,1;  C5,1;
    A4,2;  R,1;   C4,1;  E4,1;  A4,1;
    B4,2;  R,1;   E4,1;  C5,1;  B4,1;
    A4,2;  R,2;
    % Second phrase
    B4,1;  C5,1;  D5,1;  E5,2;  G4,1;  F4,1;  E4,1;
    D5,2;  F4,1;  E4,1;  D4,1;  C5,2;  E4,1;  D4,1;  C4,1;
    B3,2;  R,1;   E4,1;  E5,1;  Ds5,1;
    E5,1;  Ds5,1; E5,1;  B4,1;  D5,1;  C5,1;
    A4,2;  R,1;   C4,1;  E4,1;  A4,1;
    B4,2;  R,1;   E4,1;  C5,1;  B4,1;
    A4,4;
];

% Synthesize audio
note_gap   = 0.02;   % 20ms silence between notes (articulation)
audio_buf  = [];

for k = 1:size(score,1)
    freq     = score(k,1);
    dur_sec  = score(k,2) / tempo_bps;
    n_samp   = round(dur_sec * fs_audio);
    t_note   = (0:n_samp-1)' / fs_audio;

    if freq == 0
        note = zeros(n_samp, 1);
    else
        % Sine with smooth ADSR envelope to avoid clicks
        env     = ones(n_samp, 1);
        att     = round(0.01 * fs_audio);   % 10ms attack
        rel     = round(0.03 * fs_audio);   % 30ms release
        gap     = round(note_gap * fs_audio);
        att     = min(att, n_samp);
        rel     = min(rel, n_samp - att);
        gap     = min(gap, n_samp);
        env(1:att)          = linspace(0, 1, att);
        env(end-rel+1:end)  = linspace(1, 0, rel);
        env(end-gap+1:end)  = 0;
        note = env .* sin(2*pi*freq*t_note);
    end
    audio_buf = [audio_buf; note]; %#ok<AGROW>
end

% Normalize
audio_buf = audio_buf / max(abs(audio_buf) + 1e-9);

fprintf('Melody duration: %.1f seconds\n', length(audio_buf)/fs_audio);

%% ============================================================
%  FM MODULATE
%% ============================================================

phase_integral = cumsum(audio_buf) / fs_audio;
fm_signal      = exp(1j * 2 * pi * max_freq_dev * phase_integral);
fm_signal      = fm_signal / max(abs(fm_signal));

%% ============================================================
%  CHECK BUFFER SIZE & INTERPOLATE
%% ============================================================

% Trim to fit PlutoSDR 16M sample limit after upsampling
max_baseband_samples = floor(16777216 / interp_factor) - 100;
if length(fm_signal) > max_baseband_samples
    fm_signal = fm_signal(1:max_baseband_samples);
    audio_buf = audio_buf(1:max_baseband_samples);
    fprintf('Note: melody trimmed to %.1f sec to fit hardware buffer.\n', ...
            max_baseband_samples/fs_audio);
end

fprintf('Upsampling %dx to %.1f MHz...\n', interp_factor, fs_pluto/1e6);
fm_signal_up = resample(fm_signal, interp_factor, 1);
fm_signal_up = fm_signal_up / max(abs(fm_signal_up));
fm_signal_up = fm_signal_up * 0.9;

fprintf('Buffer: %d baseband → %d upsampled samples\n\n', ...
        length(fm_signal), length(fm_signal_up));

%% ============================================================
%  CONFIGURE & TRANSMIT
%% ============================================================

fprintf('=== PlutoSDR FM Melody Transmitter ===\n');
fprintf('Carrier   : %.2f MHz\n', fc/1e6);
fprintf('TX Gain   : %d dB\n', tx_gain);
fprintf('Melody    : Fur Elise (loops continuously)\n\n');

try
    tx = sdrtx('Pluto', 'RadioID', pluto_uri, ...
               'CenterFrequency', fc, ...
               'BasebandSampleRate', fs_pluto, ...
               'Gain', tx_gain);
catch
    fprintf('IP failed, trying USB...\n');
    tx = sdrtx('Pluto', 'RadioID', 'usb:0', ...
               'CenterFrequency', fc, ...
               'BasebandSampleRate', fs_pluto, ...
               'Gain', tx_gain);
end

fprintf('Transmitting Fur Elise on %.1f MHz — tune FM radio now!\n', fc/1e6);
fprintf('Press Ctrl+C to stop.\n\n');

% transmitRepeat loops the melody buffer endlessly
transmitRepeat(tx, fm_signal_up);

tic;
try
    while true
        fprintf('\r  Playing Fur Elise on %.1f MHz... %.0f sec elapsed', fc/1e6, toc);
        pause(0.5);
    end
catch
end

fprintf('\n\nStopped. Releasing hardware...\n');
release(tx);

%% ============================================================
%  DIAGNOSTIC PLOTS
%% ============================================================

t_audio = (0:length(audio_buf)-1)' / fs_audio;
plot_end = min(length(audio_buf), round(3*fs_audio));  % plot first 3 sec
NFFT = 4096;

figure('Name','FM Melody Diagnostics','Color','white','Position',[50 50 1300 700]);

subplot(2,3,1);
plot(t_audio(1:plot_end), audio_buf(1:plot_end), 'b', 'LineWidth', 0.8);
xlabel('Time (s)'); ylabel('Amplitude');
title('Fur Elise — Audio Waveform (first 3 sec)');
grid on; ylim([-1.3 1.3]);

subplot(2,3,2);
plot(t_audio(1:plot_end), real(fm_signal(1:plot_end)), 'r', 'LineWidth', 0.8);
xlabel('Time (s)'); ylabel('Real Part');
title('FM Signal — Real Part');
grid on;

subplot(2,3,3);
iq_end = min(length(fm_signal), 10000);
plot(real(fm_signal(1:iq_end)), imag(fm_signal(1:iq_end)), '.', ...
     'Color',[0.1 0.6 0.1], 'MarkerSize', 1);
xlabel('I'); ylabel('Q');
title('IQ Constellation — Unit Circle');
grid on; axis equal; xlim([-1.3 1.3]); ylim([-1.3 1.3]);

subplot(2,3,4);
[pxx,f] = pwelch(audio_buf, hann(NFFT), NFFT/2, NFFT, fs_audio, 'centered');
plot(f, 10*log10(pxx), 'b', 'LineWidth', 1);
xlabel('Frequency (Hz)'); ylabel('PSD (dB/Hz)');
title('Audio Spectrum — Note Frequencies Visible');
grid on; xlim([0 fs_audio/2]);

subplot(2,3,5);
[pxx_up,f_up] = pwelch(fm_signal_up, hann(NFFT), NFFT/2, NFFT, fs_pluto, 'centered');
plot(f_up/1e3, 10*log10(pxx_up), 'r', 'LineWidth', 1);
xlabel('Frequency (kHz)'); ylabel('PSD (dB/Hz)');
title(sprintf('TX Spectrum at %.1f MHz SR', fs_pluto/1e6));
grid on;

subplot(2,3,6);
inst_phase = unwrap(angle(fm_signal(1:plot_end)));
inst_freq  = diff(inst_phase)/(2*pi)*fs_audio;
plot(t_audio(2:plot_end), inst_freq/1e3, 'k', 'LineWidth', 0.8);
xlabel('Time (s)'); ylabel('Inst. Freq (kHz)');
title('Instantaneous Frequency — Follows Melody');
yline( max_freq_dev/1e3,'--r'); yline(-max_freq_dev/1e3,'--r');
grid on; ylim([-max_freq_dev/1e3*1.3, max_freq_dev/1e3*1.3]);

sgtitle(sprintf('PlutoSDR FM — Fur Elise on %.1f MHz', fc/1e6), ...
        'FontSize',13,'FontWeight','bold');
