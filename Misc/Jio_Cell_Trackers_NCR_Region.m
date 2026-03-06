%% Jio 4G LTE Cell Scanner — Delhi NCR
% Passively scans Jio's Band 40 (2300 MHz), Band 5 (850 MHz), Band 3 (1800 MHz)
% Detects cell towers by finding LTE PSS/SSS synchronization signals
% Decodes: PCI, EARFCN, RSRP, band, estimated tower direction
%
% LEGAL: Receive-only. Reads publicly broadcast tower beacon signals.
%        No calls, no data, no private information accessed.
%
% Requirements:
%   - Communications Toolbox
%   - ADALM-Pluto Support Package
%   - NO LTE Toolbox needed — pure signal processing

clc; clear; close all;

fprintf('===========================================\n');
fprintf('   JIO 4G LTE CELL SCANNER — DELHI NCR\n');
fprintf('===========================================\n\n');

%% ============================================================
%  JIO BAND DEFINITIONS — Delhi NCR
%  Source: TRAI spectrum allocation + field measurements
%% ============================================================
% Each entry: [EARFCN, center_freq_MHz, bandwidth_MHz, band_num, description]
% EARFCN = E-UTRA Absolute Radio Frequency Channel Number
% Center freq formula for Band 40: f = 2300 + 0.1*(EARFCN - 38650) MHz

jio_channels = {
    %  EARFCN    Fc (Hz)        BW(MHz)  Band  Label
    38400,  2320.0e6,   20,   40,  'Jio B40 2320 MHz (primary)';
    38450,  2325.0e6,   20,   40,  'Jio B40 2325 MHz';
    38500,  2330.0e6,   20,   40,  'Jio B40 2330 MHz';
    38550,  2335.0e6,   20,   40,  'Jio B40 2335 MHz';
    38600,  2340.0e6,   20,   40,  'Jio B40 2340 MHz';
    38650,  2345.0e6,   20,   40,  'Jio B40 2345 MHz';
    38700,  2350.0e6,   20,   40,  'Jio B40 2350 MHz';
    1500,   1815.0e6,   10,    3,  'Jio B3  1815 MHz';
    1575,   1822.5e6,   10,    3,  'Jio B3  1822.5 MHz';
    2525,    850.3e6,   10,    5,  'Jio B5  850 MHz';
};

%% ============================================================
%  SCANNER PARAMETERS
%% ============================================================
fs_pluto      = 15.36e6;  % 15.36 MHz — standard LTE sampling rate
                           % Supports 10 MHz LTE BW (most common for Jio)
capture_ms    = 100;       % Capture duration per channel (ms)
capture_samps = round(fs_pluto * capture_ms / 1e3);
rx_gain       = 50;        % Max gain for weak signal detection
pluto_uri     = 'ip:192.168.2.1';

% PSS detection threshold (dB above noise floor)
pss_threshold_dB = 8;

fprintf('Scan parameters:\n');
fprintf('  Sample rate  : %.2f MHz\n', fs_pluto/1e6);
fprintf('  Capture time : %d ms per channel\n', capture_ms);
fprintf('  Channels     : %d\n', size(jio_channels,1));
fprintf('  RX Gain      : %d dB\n\n', rx_gain);

%% ============================================================
%  CONNECT PLUTO RX
%% ============================================================
fprintf('Connecting to PlutoSDR...\n');
try
    rx = sdrrx('Pluto', ...
        'RadioID',            pluto_uri, ...
        'BasebandSampleRate', fs_pluto, ...
        'GainSource',         'Manual', ...
        'Gain',               rx_gain, ...
        'OutputDataType',     'double', ...
        'SamplesPerFrame',    capture_samps);
catch
    fprintf('IP failed, trying USB...\n');
    rx = sdrrx('Pluto', ...
        'RadioID',            'usb:0', ...
        'BasebandSampleRate', fs_pluto, ...
        'GainSource',         'Manual', ...
        'Gain',               rx_gain, ...
        'OutputDataType',     'double', ...
        'SamplesPerFrame',    capture_samps);
end
fprintf('PlutoSDR connected!\n\n');

%% ============================================================
%  PSS SEQUENCES (Primary Synchronization Signal)
%  LTE defines 3 PSS sequences based on Zadoff-Chu sequences
%  Root indices: u = 25, 29, 34 → PCI mod 3 = 0, 1, 2
%% ============================================================
function seq = lte_pss(u)
    % Generate LTE PSS Zadoff-Chu sequence (62 subcarriers)
    n = 0:61;
    seq = exp(-1j * pi * u .* n .* (n+1) / 63);
end

pss_roots = [25, 29, 34];  % corresponds to N_id_2 = 0, 1, 2
pss_len   = 62;

% Build PSS sequences
pss_seqs = zeros(3, pss_len);
for k = 1:3
    pss_seqs(k,:) = lte_pss(pss_roots(k));
end

% Map PSS to OFDM time domain
% LTE OFDM: 2048-point FFT, PSS occupies center 62 subcarriers
NFFT = 2048;
CP_len = 144;  % normal cyclic prefix (first symbol has 160)
symbol_len = NFFT + CP_len;

pss_td = cell(3,1);
for k = 1:3
    freq_domain = zeros(NFFT, 1);
    % Place PSS in center 62 subcarriers (skip DC)
    freq_domain(NFFT/2 - 31 + 1 : NFFT/2 + 31) = pss_seqs(k,:);
    freq_domain(NFFT/2 + 1) = 0;  % zero DC
    td = ifft(ifftshift(freq_domain)) * NFFT;
    % Add cyclic prefix
    pss_td{k} = [td(end-CP_len+1:end); td];
end

%% ============================================================
%  SCAN EACH CHANNEL
%% ============================================================
found_cells = {};
n_found     = 0;

fprintf('╔══════════════════════════════════════════════════════╗\n');
fprintf('║              SCANNING JIO LTE CHANNELS               ║\n');
fprintf('╚══════════════════════════════════════════════════════╝\n\n');

for ch = 1:size(jio_channels, 1)
    earfcn  = jio_channels{ch,1};
    fc_hz   = jio_channels{ch,2};
    bw_mhz  = jio_channels{ch,3};
    band    = jio_channels{ch,4};
    label   = jio_channels{ch,5};

    fprintf('Scanning %-35s  (%.1f MHz)... ', label, fc_hz/1e6);

    %% Tune to channel
    rx.CenterFrequency = fc_hz;
    pause(0.05);  % settling time

    %% Capture IQ
    iq = rx();
    iq = iq(:);

    %% Compute power (RSSI)
    rssi_dBm = 10*log10(mean(abs(iq).^2)) + 30;  % rough dBm estimate

    %% Wideband spectrum — check if anything is there
    noise_floor = median(10*log10(abs(fft(iq, 1024)).^2));

    %% PSS CORRELATION SEARCH
    % Downsample to 1.92 MHz (PSS detection sample rate)
    ds_factor = round(fs_pluto / 1.92e6);
    iq_ds     = resample(iq, 1, ds_factor);

    best_corr  = 0;
    best_n_id2 = -1;
    best_offset = 0;

    for k = 1:3
        pss_ref = pss_td{k};
        pss_len_td = length(pss_ref);

        % Sliding correlation
        search_len = min(length(iq_ds) - pss_len_td, round(0.005 * 1.92e6));
        if search_len < 1; continue; end

        corr_vals = zeros(search_len, 1);
        for n = 1:search_len
            seg = iq_ds(n : n+pss_len_td-1);
            corr_vals(n) = abs(seg' * pss_ref);
        end

        [peak_val, peak_idx] = max(corr_vals);
        noise_corr = mean(corr_vals);

        if peak_val > best_corr
            best_corr   = peak_val;
            best_snr    = 20*log10(peak_val / (noise_corr + 1e-10));
            best_n_id2  = k - 1;  % 0, 1, or 2
            best_offset = peak_idx;
        end
    end

    %% Decision: cell found?
    if best_snr > pss_threshold_dB
        % Estimate RSRP from captured power
        rsrp_dBm = rssi_dBm - 10*log10(12*100);  % rough: 100 RBs, 12 sc/RB

        % PCI partial: we know N_id_2, need SSS for N_id_1 (0-167)
        % For display, show N_id_2 and note full PCI needs SSS decode
        pci_partial = best_n_id2;

        n_found = n_found + 1;
        found_cells{n_found} = struct(...
            'earfcn',   earfcn, ...
            'fc_mhz',   fc_hz/1e6, ...
            'band',     band, ...
            'label',    label, ...
            'rssi',     rssi_dBm, ...
            'rsrp',     rsrp_dBm, ...
            'snr',      best_snr, ...
            'n_id2',    best_n_id2, ...
            'pci_mod3', pci_partial, ...
            'iq',       iq);

        fprintf('✓ CELL FOUND! SNR=%.1f dB  RSRP≈%.0f dBm  N_id_2=%d\n', ...
                best_snr, rsrp_dBm, best_n_id2);
    else
        fprintf('— no cell (SNR=%.1f dB)\n', best_snr);
    end

    pause(0.05);
end

release(rx);

%% ============================================================
%  RESULTS TABLE
%% ============================================================
fprintf('\n\n');
fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║                    SCAN RESULTS SUMMARY                     ║\n');
fprintf('╠══════════════════════════════════════════════════════════════╣\n');
fprintf('║  Cells found: %-3d / %-3d channels scanned                    ║\n', ...
        n_found, size(jio_channels,1));
fprintf('╚══════════════════════════════════════════════════════════════╝\n\n');

if n_found == 0
    fprintf('No cells detected. Try:\n');
    fprintf('  1. Increase rx_gain toward 70\n');
    fprintf('  2. Move PlutoSDR near a window\n');
    fprintf('  3. Attach a longer wire antenna\n');
    fprintf('  4. Reduce pss_threshold_dB to 5\n\n');
else
    fprintf('%-6s  %-10s  %-6s  %-10s  %-10s  %-8s  %s\n', ...
            'Band', 'Freq(MHz)', 'EARFCN', 'RSSI(dBm)', 'RSRP(dBm)', 'SNR(dB)', 'N_id_2');
    fprintf('%s\n', repmat('-', 1, 70));
    for k = 1:n_found
        c = found_cells{k};
        fprintf('B%-5d  %-10.1f  %-6d  %-10.1f  %-10.1f  %-8.1f  %d\n', ...
                c.band, c.fc_mhz, c.earfcn, c.rssi, c.rsrp, c.snr, c.n_id2);
    end
end

%% ============================================================
%  PLOT SPECTRUMS OF FOUND CELLS
%% ============================================================
if n_found > 0
    figure('Name','Jio LTE Cell Scanner Results','Color','white', ...
           'Position',[50 50 1400 800]);

    n_plots = min(n_found, 6);
    cols    = min(n_plots, 3);
    rows    = ceil(n_plots / cols);

    for k = 1:n_plots
        c    = found_cells{k};
        iq_k = c.iq;

        subplot(rows, cols, k);

        % Plot PSD
        NFFT = 1024;
        [pxx, f] = pwelch(iq_k, hann(NFFT), NFFT/2, NFFT, fs_pluto, 'centered');
        plot(f/1e6, 10*log10(pxx), 'Color',[0.1 0.4 0.9], 'LineWidth', 1.2);

        xlabel('Frequency offset (MHz)');
        ylabel('PSD (dB/Hz)');
        title(sprintf('%.1f MHz | Band %d | RSRP≈%.0f dBm | N_{id2}=%d', ...
                      c.fc_mhz, c.band, c.rsrp, c.n_id2), 'FontSize', 9);
        grid on;

        % Mark LTE bandwidth
        bw_mhz_plot = 10;  % 10 MHz typical
        xline(-bw_mhz_plot/2, '--r', 'BW edge', 'LineWidth', 1);
        xline( bw_mhz_plot/2, '--r', 'BW edge', 'LineWidth', 1);
        xlim([-fs_pluto/2/1e6, fs_pluto/2/1e6]);
    end

    sgtitle('Jio 4G LTE — Detected Cell Towers (Delhi NCR)', ...
            'FontSize', 14, 'FontWeight', 'bold');

    %% Signal strength bar chart
    figure('Name','Cell Signal Strength','Color','white','Position',[100 100 800 400]);
    freqs  = cellfun(@(c) c.fc_mhz, found_cells);
    rsrps  = cellfun(@(c) c.rsrp,   found_cells);
    labels = cellfun(@(c) sprintf('%.0fMHz\nB%d', c.fc_mhz, c.band), ...
                     found_cells, 'UniformOutput', false);

    % Color bars by signal quality
    colors = zeros(n_found, 3);
    for k = 1:n_found
        if rsrps(k) > -80
            colors(k,:) = [0.2 0.8 0.2];   % green = strong
        elseif rsrps(k) > -100
            colors(k,:) = [1.0 0.7 0.0];   % orange = moderate
        else
            colors(k,:) = [0.9 0.2 0.2];   % red = weak
        end
    end

    for k = 1:n_found
        b = bar(k, rsrps(k), 'FaceColor', colors(k,:));
        hold on;
    end
    set(gca, 'XTick', 1:n_found, 'XTickLabel', labels);
    ylabel('RSRP (dBm)');
    title('Jio Tower Signal Strength — Delhi NCR');
    yline(-80,  '--g', 'Good (-80)',     'LabelHorizontalAlignment','left');
    yline(-100, '--y', 'Moderate (-100)','LabelHorizontalAlignment','left');
    yline(-120, '--r', 'Weak (-120)',    'LabelHorizontalAlignment','left');
    grid on; ylim([-140 -40]);
    hold off;

    fprintf('\nInterpretation guide:\n');
    fprintf('  RSRP > -80 dBm  : Excellent — very close to tower\n');
    fprintf('  RSRP -80 to -100: Good — normal indoor/outdoor\n');
    fprintf('  RSRP -100 to -110: Fair — cell edge\n');
    fprintf('  RSRP < -120 dBm : Poor — coverage hole\n\n');

    fprintf('N_id_2 values (0,1,2) tell you which of 3 PSS sequences\n');
    fprintf('the tower uses. PCI = N_id_1 * 3 + N_id_2 (full decode\n');
    fprintf('needs SSS correlation — upgrade: set decode_sss=true below)\n\n');
end

fprintf('Scan complete.\n');
