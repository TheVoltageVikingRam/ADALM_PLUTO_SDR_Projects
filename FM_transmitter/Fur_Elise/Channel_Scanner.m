%% ADALM PlutoSDR - FM Band Scanner
% Scans the FM band (87.5 - 108 MHz) and plots power spectral density
% Use this BEFORE transmitting to identify a quiet channel
%
% Requirements: Same as pluto_fm_transmit.m

clc; clear; close all;

%% Parameters
scan_start  = 87.5e6;   % FM band start
scan_end    = 108.0e6;  % FM band end
step        = 200e3;    % Step size (200 kHz = standard FM channel spacing)
fs_pluto    = 2.8e6;    % RX sample rate (covers ~14 channels per step)
rx_gain     = 40;       % RX gain in dB
capture_ms  = 50;       % Capture time per step in ms
pluto_uri   = 'usb:0';

%% Scan
freqs = scan_start : step : scan_end;
power_dB = zeros(size(freqs));

fprintf('Connecting to PlutoSDR for FM scan...\n');
rx = sdrrx('Pluto', ...
    'RadioID',            pluto_uri, ...
    'CenterFrequency',    freqs(1), ...
    'BasebandSampleRate', fs_pluto, ...
    'GainSource',         'Manual', ...
    'Gain',               rx_gain, ...
    'OutputDataType',     'single', ...
    'SamplesPerFrame',    round(fs_pluto * capture_ms / 1e3));

fprintf('Scanning FM band %.1f - %.1f MHz...\n', scan_start/1e6, scan_end/1e6);

for k = 1:length(freqs)
    rx.CenterFrequency = freqs(k);
    pause(0.02); % Settle time
    data = rx();
    power_dB(k) = 10 * log10(mean(abs(data).^2) + 1e-20);
    fprintf('  %.1f MHz : %.1f dB\n', freqs(k)/1e6, power_dB(k));
end

release(rx);

%% Plot results
figure('Name', 'FM Band Scan', 'Position', [100 100 900 400]);
bar(freqs/1e6, power_dB, 'FaceColor', [0.2 0.5 0.8]);
xlabel('Frequency (MHz)');
ylabel('Received Power (dB)');
title('FM Band Power Scan — Lower = Quieter Channel');
grid on;

% Mark quietest channel
[~, idx_quiet] = min(power_dB);
xline(freqs(idx_quiet)/1e6, '--r', ...
      sprintf('Quietest: %.1f MHz', freqs(idx_quiet)/1e6), ...
      'LabelVerticalAlignment', 'bottom', 'LineWidth', 1.5);

fprintf('\nQuietest channel: %.1f MHz (%.1f dB)\n', ...
        freqs(idx_quiet)/1e6, power_dB(idx_quiet));
fprintf('Set fc = %.1f in pluto_fm_transmit.m\n', freqs(idx_quiet)/1e6);
