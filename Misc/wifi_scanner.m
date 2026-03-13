%% PlutoSDR — 2.4 GHz Wi-Fi Band Scanner
%  Scans all 13 Wi-Fi channels, measures RSSI, detects active channels
%  Run this first — paste the printed report back to get optimized TX code
%
%  RX only — completely safe to run anywhere

clc; clear; close all;

%% ── Parameters ───────────────────────────────────────────────────────────────
samp_rate    = 20e6;        % RX sample rate
rx_gain      = 50;          % High gain for scanning (dB)
dwell_time   = 0.3;         % Seconds to listen per channel
fft_size     = 8192;        % Large FFT for good frequency resolution

% All 13 Wi-Fi channel centre frequencies (2.4 GHz band)
ch_num   = 1:13;
ch_freq  = 2.407e9 + ch_num * 5e6;   % Ch1=2.412, Ch2=2.417 ... Ch13=2.472 GHz
ch_bw    = 20e6;                      % Standard Wi-Fi channel BW

%% ── Connect PlutoSDR in RX mode ──────────────────────────────────────────────
fprintf('Connecting to PlutoSDR for Wi-Fi scan...\n');
try
    rx = sdrrx('Pluto', ...
        'RadioID',            'ip:192.168.2.1', ...
        'CenterFrequency',    ch_freq(1), ...
        'BasebandSampleRate', samp_rate, ...
        'SamplesPerFrame',    samp_rate * dwell_time, ...
        'GainSource',         'Manual', ...
        'Gain',               rx_gain, ...
        'OutputDataType',     'double');
    fprintf('Connected via ip:192.168.2.1\n\n');
catch
    fprintf('IP failed, trying USB...\n');
    rx = sdrrx('Pluto', ...
        'RadioID',            'usb:0', ...
        'CenterFrequency',    ch_freq(1), ...
        'BasebandSampleRate', samp_rate, ...
        'SamplesPerFrame',    samp_rate * dwell_time, ...
        'GainSource',         'Manual', ...
        'Gain',               rx_gain, ...
        'OutputDataType',     'double');
    fprintf('Connected via usb:0\n\n');
end

%% ── Scan all channels ────────────────────────────────────────────────────────
fprintf('Scanning 2.4 GHz band — please wait (~%.0f sec)...\n\n', ...
        numel(ch_num) * dwell_time * 1.5);

results = struct();

for k = 1:numel(ch_num)
    rx.CenterFrequency = ch_freq(k);
    pause(0.05);  % Let AGC settle

    % Capture samples (grab 2, discard first for transient)
    step(rx);
    [samples, ~, overflow] = step(rx);

    % Power spectral density
    win      = hann(fft_size);
    n_chunks = floor(length(samples) / fft_size);
    psd_avg  = zeros(fft_size, 1);
    for c = 1:n_chunks
        seg      = samples((c-1)*fft_size+1 : c*fft_size);
        S        = fftshift(fft(seg .* win, fft_size));
        psd_avg  = psd_avg + abs(S).^2;
    end
    psd_avg  = psd_avg / n_chunks;
    psd_db   = 10*log10(psd_avg / fft_size + eps);

    % Frequency axis
    f_axis = ch_freq(k) + linspace(-samp_rate/2, samp_rate/2, fft_size);

    % Key metrics
    noise_floor  = median(psd_db);                    % dB
    peak_power   = max(psd_db);                       % dB
    avg_power    = mean(psd_db);                      % dB
    snr_est      = peak_power - noise_floor;          % dB above noise
    occupied     = (peak_power - noise_floor) > 10;  % >10 dB above floor = active

    % Peak frequency within channel
    [~, peak_idx]  = max(psd_db);
    peak_freq_mhz  = f_axis(peak_idx) / 1e6;

    % Bandwidth estimate (above noise+6dB threshold)
    threshold   = noise_floor + 6;
    active_bins = f_axis(psd_db > threshold);
    if ~isempty(active_bins)
        est_bw_mhz = (max(active_bins) - min(active_bins)) / 1e6;
    else
        est_bw_mhz = 0;
    end

    % Store
    results(k).channel     = ch_num(k);
    results(k).freq_ghz    = ch_freq(k)/1e9;
    results(k).peak_db     = peak_power;
    results(k).noise_db    = noise_floor;
    results(k).avg_db      = avg_power;
    results(k).snr_db      = snr_est;
    results(k).occupied    = occupied;
    results(k).peak_f_mhz  = peak_freq_mhz;
    results(k).est_bw_mhz  = est_bw_mhz;
    results(k).overflow    = overflow;
    results(k).psd_db      = psd_db;
    results(k).f_axis      = f_axis;

    % Live progress
    status = '  CLEAR';
    if occupied; status = '★ ACTIVE'; end
    fprintf('Ch%2d  %6.3f GHz  Peak:%6.1f dB  SNR:%5.1f dB  BW:~%4.1f MHz  %s\n', ...
        ch_num(k), ch_freq(k)/1e9, peak_power, snr_est, est_bw_mhz, status);
end

release(rx);

%% ── Summary Report (paste this back) ────────────────────────────────────────
fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║         PLUTO SDR — 2.4 GHz Wi-Fi SCAN REPORT               ║\n');
fprintf('╠══════════════════════════════════════════════════════════════╣\n');
fprintf('║  Scan time     : %s\n', datestr(now));
fprintf('║  Sample rate   : %.0f MHz\n', samp_rate/1e6);
fprintf('║  RX gain       : %d dB\n', rx_gain);
fprintf('║  Dwell/channel : %.1f sec\n', dwell_time);
fprintf('╠════╦════════╦══════════╦══════════╦══════════╦══════════════╣\n');
fprintf('║ Ch ║  Freq  ║ Peak(dB) ║  SNR(dB) ║  BW(MHz) ║   Status     ║\n');
fprintf('╠════╬════════╬══════════╬══════════╬══════════╬══════════════╣\n');

active_channels  = [];
clear_channels   = [];
strongest_ch     = 0;
strongest_snr    = -inf;

for k = 1:numel(results)
    r = results(k);
    if r.occupied
        stat_str = '★ ACTIVE     ';
        active_channels(end+1) = r.channel; %#ok<AGROW>
        if r.snr_db > strongest_snr
            strongest_snr = r.snr_db;
            strongest_ch  = r.channel;
        end
    else
        stat_str = '  clear      ';
        clear_channels(end+1) = r.channel; %#ok<AGROW>
    end
    fprintf('║ %2d ║ %6.3f ║   %6.1f ║   %6.1f ║   %6.1f ║ %s║\n', ...
        r.channel, r.freq_ghz, r.peak_db, r.snr_db, r.est_bw_mhz, stat_str);
end

fprintf('╚════╩════════╩══════════╩══════════╩══════════╩══════════════╝\n\n');

fprintf('ACTIVE channels  : [%s]\n', num2str(active_channels));
fprintf('CLEAR  channels  : [%s]\n', num2str(clear_channels));
fprintf('Strongest signal : Ch %d (SNR = %.1f dB)\n', strongest_ch, strongest_snr);
fprintf('Noise floor est  : %.1f dB (median across band)\n', ...
        median([results.noise_db]));
fprintf('\n');

%% ── Spectrum Waterfall Plot ───────────────────────────────────────────────────
fig = figure('Name','2.4 GHz Wi-Fi Band Scan','Color','k','Position',[50 50 1400 600]);

ax = axes('Parent',fig,'Color','k','XColor','w','YColor','w');
hold(ax,'on');

colors_active = [1.0 0.3 0.2];
colors_clear  = [0.2 0.6 1.0];

for k = 1:numel(results)
    r = results(k);
    if r.occupied
        plot(ax, r.f_axis/1e9, r.psd_db, 'Color', colors_active, 'LineWidth', 0.8);
    else
        plot(ax, r.f_axis/1e9, r.psd_db, 'Color', colors_clear,  'LineWidth', 0.5, ...
             'Color', [colors_clear 0.5]);
    end
end

% Channel markers
for k = 1:13
    f_ghz = ch_freq(k)/1e9;
    xline(ax, f_ghz, '--', 'Color',[1 0.8 0],'Alpha',0.5, ...
          'Label', sprintf('Ch%d',k), 'LabelVerticalAlignment','bottom', ...
          'FontSize',8, 'LabelColor',[1 0.8 0]);
end

xlabel(ax,'Frequency (GHz)','Color','w','FontSize',12);
ylabel(ax,'Power (dB)','Color','w','FontSize',12);
title(ax, sprintf('2.4 GHz Wi-Fi Band Scan  |  Active: Ch[%s]  |  Clear: Ch[%s]', ...
     num2str(active_channels), num2str(clear_channels)), ...
     'Color','w','FontSize',12);
xlim(ax,[2.400 2.485]);
grid(ax,'on'); ax.GridColor=[0.25 0.25 0.25];

% Legend
plot(ax,NaN,NaN,'Color',colors_active,'LineWidth',2,'DisplayName','Active channel');
plot(ax,NaN,NaN,'Color',colors_clear, 'LineWidth',2,'DisplayName','Clear channel');
legend(ax,'TextColor','w','Color','k','EdgeColor','w','Location','northeast');

hold(ax,'off');

%% ── Per-channel bar chart ────────────────────────────────────────────────────
figure('Name','Channel Activity','Color','k','Position',[50 680 700 280]);
ax2 = axes('Color','k','XColor','w','YColor','w');
snr_vals = [results.snr_db];
bar_colors = repmat([0.2 0.6 1.0], 13, 1);
for k = 1:13
    if results(k).occupied
        bar_colors(k,:) = colors_active;
    end
end
b = bar(ax2, ch_num, snr_vals, 'FaceColor','flat');
b.CData = bar_colors;
xlabel(ax2,'Wi-Fi Channel','Color','w');
ylabel(ax2,'SNR above noise (dB)','Color','w');
title(ax2,'Channel Activity — SNR per Channel','Color','w');
yline(ax2, 10,'--w','Label','Active threshold','LabelHorizontalAlignment','left', ...
      'FontSize',9,'Color',[1 1 1 0.6]);
grid(ax2,'on'); ax2.GridColor=[0.25 0.25 0.25];
set(ax2,'XTick',1:13);
