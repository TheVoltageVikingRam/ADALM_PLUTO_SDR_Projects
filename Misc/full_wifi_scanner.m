%% PlutoSDR — Full Wi-Fi Scanner (2.4 GHz + 5 GHz)
%  Scans both bands, extracts critical parameters, produces publication-quality plots
%
%  Outputs:
%    1. Live channel-by-channel progress in Command Window
%    2. Full summary report table
%    3. Figure 1 — 2.4 GHz full band spectrum overlay
%    4. Figure 2 — 5 GHz band spectrum overlay
%    5. Figure 3 — SNR heatmap both bands
%    6. Figure 4 — Channel congestion radar/polar chart
%    7. Figure 5 — Critical parameters dashboard
%
%  Requirements: Communications Toolbox + Pluto Support Package

clc; clear; close all;

%% ═══════════════════════════════════════════════════════════════════
%  CONFIGURATION
%% ═══════════════════════════════════════════════════════════════════
samp_rate_24  = 20e6;       % 2.4 GHz scan sample rate
samp_rate_5   = 20e6;       % 5 GHz scan sample rate
rx_gain       = 60;         % dB — high for maximum sensitivity
dwell_time    = 0.4;        % seconds per channel
fft_size      = 8192;       % frequency resolution
snr_threshold = 8;          % dB above noise floor = occupied

%% ── 2.4 GHz channel plan (Ch 1-13) ──────────────────────────────
ch24_num  = 1:13;
ch24_freq = 2.407e9 + ch24_num * 5e6;
ch24_name = arrayfun(@(x) sprintf('2.4G-Ch%d',x), ch24_num, 'UniformOutput', false);

%% ── 5 GHz channel plan (UNII-1, UNII-2, UNII-2e, UNII-3) ───────
% Standard 5 GHz 20 MHz channels available in India
ch5_num  = [36,  40,  44,  48, ...   % UNII-1
            52,  56,  60,  64, ...   % UNII-2
           100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, ...  % UNII-2e
           149, 153, 157, 161, 165]; % UNII-3
ch5_freq = 5e9 + ch5_num * 5e6;
ch5_name = arrayfun(@(x) sprintf('5G-Ch%d',x), ch5_num, 'UniformOutput', false);

%% ═══════════════════════════════════════════════════════════════════
%  CONNECT PLUTOSDR
%% ═══════════════════════════════════════════════════════════════════
fprintf('╔══════════════════════════════════════════════╗\n');
fprintf('║   PlutoSDR Full Wi-Fi Scanner Starting...    ║\n');
fprintf('╚══════════════════════════════════════════════╝\n\n');

connected = false;
for attempt = 1:2
    try
        radio_id = 'ip:192.168.2.1';
        if attempt == 2; radio_id = 'usb:0'; end
        rx = sdrrx('Pluto', ...
            'RadioID',            radio_id, ...
            'CenterFrequency',    ch24_freq(1), ...
            'BasebandSampleRate', samp_rate_24, ...
            'SamplesPerFrame',    round(samp_rate_24 * dwell_time), ...
            'GainSource',         'Manual', ...
            'Gain',               rx_gain, ...
            'OutputDataType',     'double');
        fprintf('✓ Connected via %s\n\n', radio_id);
        connected = true;
        break;
    catch e
        fprintf('✗ %s failed: %s\n', radio_id, e.message);
    end
end
if ~connected
    error('PlutoSDR not found. Check connection and try again.');
end

%% ═══════════════════════════════════════════════════════════════════
%  SCAN FUNCTION (reused for both bands)
%% ═══════════════════════════════════════════════════════════════════
function R = scan_channel(rx, freq, samp_rate, fft_size, snr_threshold, ch_label)
    rx.CenterFrequency    = freq;


    pause(0.08);  % settle

    % Discard first capture (transient)
    try; step(rx); catch; end

    % Capture
    try
        [samples, ~, overflow] = step(rx);
    catch
        samples = zeros(round(samp_rate*0.4),1);
        overflow = false;
    end

    % Welch PSD
    win     = hann(fft_size);
    n_chunks = floor(length(samples)/fft_size);
    if n_chunks < 1
        n_chunks = 1;
        samples  = [samples; zeros(fft_size - length(samples), 1)];
    end
    psd_avg = zeros(fft_size,1);
    for c = 1:n_chunks
        seg     = samples((c-1)*fft_size+1 : c*fft_size);
        S       = fftshift(fft(seg .* win, fft_size));
        psd_avg = psd_avg + abs(S).^2;
    end
    psd_avg  = psd_avg / n_chunks;
    psd_db   = 10*log10(psd_avg/fft_size + eps);
    f_axis   = freq + linspace(-samp_rate/2, samp_rate/2, fft_size);

    % Metrics
    noise_floor = median(psd_db);
    peak_db     = max(psd_db);
    avg_db      = mean(psd_db);
    snr_db      = peak_db - noise_floor;
    occupied    = snr_db > snr_threshold;

    [~,peak_idx] = max(psd_db);
    peak_f_mhz   = f_axis(peak_idx)/1e6;

    thresh       = noise_floor + 6;
    active_bins  = f_axis(psd_db > thresh);
    est_bw_mhz   = 0;
    if ~isempty(active_bins)
        est_bw_mhz = (max(active_bins)-min(active_bins))/1e6;
    end

    % Channel utilization (% of bandwidth above threshold)
    utilization = 100 * sum(psd_db > thresh) / fft_size;

    R.label       = ch_label;
    R.freq_ghz    = freq/1e9;
    R.peak_db     = peak_db;
    R.noise_db    = noise_floor;
    R.avg_db      = avg_db;
    R.snr_db      = snr_db;
    R.occupied    = occupied;
    R.peak_f_mhz  = peak_f_mhz;
    R.est_bw_mhz  = est_bw_mhz;
    R.utilization = utilization;
    R.overflow    = overflow;
    R.psd_db      = psd_db;
    R.f_axis      = f_axis;
    R.samp_rate   = samp_rate;
end

%% ═══════════════════════════════════════════════════════════════════
%  SCAN 2.4 GHz BAND
%% ═══════════════════════════════════════════════════════════════════
fprintf('┌─────────────────────────────────────────────────────────────┐\n');
fprintf('│  Scanning 2.4 GHz Band (13 channels × %.1f sec)...          │\n', dwell_time);
fprintf('└─────────────────────────────────────────────────────────────┘\n');

r24 = struct([]);
for k = 1:numel(ch24_num)
    R = scan_channel(rx, ch24_freq(k), samp_rate_24, fft_size, snr_threshold, ch24_name{k});
    r24 = [r24, R]; %#ok<AGROW>
    status = '  clear  ';
    if R.occupied; status = '★ ACTIVE '; end
    fprintf('  Ch%2d  %6.3f GHz  Peak:%6.1f dB  SNR:%5.1f dB  BW:%5.1f MHz  Util:%4.1f%%  %s\n', ...
        ch24_num(k), R.freq_ghz, R.peak_db, R.snr_db, R.est_bw_mhz, R.utilization, status);
end

%% ═══════════════════════════════════════════════════════════════════
%  SCAN 5 GHz BAND
%% ═══════════════════════════════════════════════════════════════════
fprintf('\n┌─────────────────────────────────────────────────────────────┐\n');
fprintf('│  Scanning 5 GHz Band (%d channels × %.1f sec)...             │\n', numel(ch5_num), dwell_time);
fprintf('└─────────────────────────────────────────────────────────────┘\n');

r5 = struct([]);
for k = 1:numel(ch5_num)
    R = scan_channel(rx, ch5_freq(k), samp_rate_5, fft_size, snr_threshold, ch5_name{k});
    r5 = [r5, R]; %#ok<AGROW>
    status = '  clear  ';
    if R.occupied; status = '★ ACTIVE '; end
    fprintf('  Ch%3d  %6.3f GHz  Peak:%6.1f dB  SNR:%5.1f dB  BW:%5.1f MHz  Util:%4.1f%%  %s\n', ...
        ch5_num(k), R.freq_ghz, R.peak_db, R.snr_db, R.est_bw_mhz, R.utilization, status);
end

release(rx);

%% ═══════════════════════════════════════════════════════════════════
%  SUMMARY REPORT
%% ═══════════════════════════════════════════════════════════════════
all_results = [r24, r5];
active24    = sum([r24.occupied]);
active5     = sum([r5.occupied]);
noise24     = median([r24.noise_db]);
noise5      = median([r5.noise_db]);

[~,idx24]   = max([r24.snr_db]);
[~,idx5]    = max([r5.snr_db]);

fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════════════════╗\n');
fprintf('║          PLUTO SDR — FULL WI-FI SCAN REPORT                     ║\n');
fprintf('╠══════════════════════════════════════════════════════════════════╣\n');
fprintf('║  Scan time       : %-44s║\n', datestr(now));
fprintf('║  2.4 GHz active  : %2d / 13 channels                             ║\n', active24);
fprintf('║  5 GHz active    : %2d / %2d channels                             ║\n', active5, numel(ch5_num));
fprintf('║  2.4 GHz noise   : %+.1f dB                                     ║\n', noise24);
fprintf('║  5 GHz noise     : %+.1f dB                                     ║\n', noise5);
fprintf('║  Strongest 2.4G  : %-10s  SNR = %5.1f dB                  ║\n', r24(idx24).label, r24(idx24).snr_db);
fprintf('║  Strongest 5G    : %-10s  SNR = %5.1f dB                  ║\n', r5(idx5).label,  r5(idx5).snr_db);
fprintf('╠════════════════╦══════════╦══════════╦══════════╦═══════════════╣\n');
fprintf('║ Channel        ║ Peak(dB) ║  SNR(dB) ║  BW(MHz) ║  Utilization  ║\n');
fprintf('╠════════════════╬══════════╬══════════╬══════════╬═══════════════╣\n');
for k = 1:numel(r24)
    if r24(k).occupied
        fprintf('║ %-14s ║  %6.1f  ║  %6.1f  ║  %6.1f  ║   %5.1f%%  ★    ║\n', ...
            r24(k).label, r24(k).peak_db, r24(k).snr_db, r24(k).est_bw_mhz, r24(k).utilization);
    end
end
fprintf('╠════════════════╬══════════╬══════════╬══════════╬═══════════════╣\n');
for k = 1:numel(r5)
    if r5(k).occupied
        fprintf('║ %-14s ║  %6.1f  ║  %6.1f  ║  %6.1f  ║   %5.1f%%  ★    ║\n', ...
            r5(k).label, r5(k).peak_db, r5(k).snr_db, r5(k).est_bw_mhz, r5(k).utilization);
    end
end
fprintf('╚════════════════╩══════════╩══════════╩══════════╩═══════════════╝\n\n');

%% ═══════════════════════════════════════════════════════════════════
%  FIGURE 1 — 2.4 GHz Full Band Spectrum
%% ═══════════════════════════════════════════════════════════════════
fig1 = figure('Name','2.4 GHz Wi-Fi Spectrum','Color','k', ...
              'Position',[20 500 1300 420]);
ax = axes('Color','k','XColor','w','YColor','w');
hold(ax,'on');

cmap = cool(13);
for k = 1:numel(r24)
    alpha_val = 0.5 + 0.5*(r24(k).snr_db / max([r24.snr_db]));
    col = cmap(k,:);
    if r24(k).occupied
        plot(ax, r24(k).f_axis/1e9, r24(k).psd_db, ...
             'Color', [col, alpha_val], 'LineWidth', 1.0);
    else
        plot(ax, r24(k).f_axis/1e9, r24(k).psd_db, ...
             'Color', [0.3 0.3 0.3 0.4], 'LineWidth', 0.5);
    end
end

% Channel labels at peak
for k = 1:numel(r24)
    if r24(k).occupied
        text(ax, r24(k).freq_ghz, r24(k).peak_db + 1.5, ...
             sprintf('Ch%d\n%.0fdB', ch24_num(k), r24(k).snr_db), ...
             'Color','w','FontSize',7,'HorizontalAlignment','center');
    end
    xline(ax, r24(k).freq_ghz,'--','Color',[1 1 0 0.25],'LineWidth',0.5);
end

yline(ax, noise24, ':','Color',[0.7 0.7 0.7],'LineWidth',1, ...
      'Label','Noise floor','LabelHorizontalAlignment','left', ...
      'FontSize',9,'LabelColor',[0.8 0.8 0.8]);

xlabel(ax,'Frequency (GHz)','Color','w','FontSize',11);
ylabel(ax,'Power Spectral Density (dB)','Color','w','FontSize',11);
title(ax, sprintf('2.4 GHz Wi-Fi Band Scan  —  %d/%d channels active  |  Noise floor: %.1f dB', ...
      active24, 13, noise24), 'Color','w','FontSize',12,'FontWeight','bold');
xlim(ax,[2.399 2.485]); grid(ax,'on'); ax.GridColor=[0.2 0.2 0.2];

%% ═══════════════════════════════════════════════════════════════════
%  FIGURE 2 — 5 GHz Full Band Spectrum
%% ═══════════════════════════════════════════════════════════════════
fig2 = figure('Name','5 GHz Wi-Fi Spectrum','Color','k', ...
              'Position',[20 50 1300 420]);
ax2 = axes('Color','k','XColor','w','YColor','w');
hold(ax2,'on');

cmap5 = autumn(numel(ch5_num));
for k = 1:numel(r5)
    if r5(k).occupied
        plot(ax2, r5(k).f_axis/1e9, r5(k).psd_db, ...
             'Color', cmap5(k,:), 'LineWidth', 1.0);
        text(ax2, r5(k).freq_ghz, r5(k).peak_db+1.5, ...
             sprintf('Ch%d', ch5_num(k)), ...
             'Color','w','FontSize',7,'HorizontalAlignment','center');
    else
        plot(ax2, r5(k).f_axis/1e9, r5(k).psd_db, ...
             'Color',[0.25 0.25 0.25 0.35],'LineWidth',0.4);
    end
    xline(ax2, r5(k).freq_ghz,'--','Color',[1 1 0 0.15],'LineWidth',0.4);
end

yline(ax2, noise5, ':','Color',[0.7 0.7 0.7],'LineWidth',1, ...
      'Label','Noise floor','LabelHorizontalAlignment','left', ...
      'FontSize',9,'LabelColor',[0.8 0.8 0.8]);

xlabel(ax2,'Frequency (GHz)','Color','w','FontSize',11);
ylabel(ax2,'Power Spectral Density (dB)','Color','w','FontSize',11);
title(ax2, sprintf('5 GHz Wi-Fi Band Scan  —  %d/%d channels active  |  Noise floor: %.1f dB', ...
      active5, numel(ch5_num), noise5), 'Color','w','FontSize',12,'FontWeight','bold');
xlim(ax2,[min(ch5_freq)/1e9-0.01, max(ch5_freq)/1e9+0.01]);
grid(ax2,'on'); ax2.GridColor=[0.2 0.2 0.2];

% UNII band separators
unii_edges = [5.15 5.25 5.35 5.47 5.725 5.85];
unii_names = {'UNII-1','UNII-2','UNII-2e','UNII-3'};
unii_mids  = [5.200 5.310 5.600 5.787];
for i = 1:numel(unii_edges)
    xline(ax2, unii_edges(i),'Color',[0.5 0.5 0.5 0.5],'LineWidth',1.2);
end
for i = 1:numel(unii_names)
    text(ax2, unii_mids(i), min([r5.psd_db])+3, unii_names{i}, ...
         'Color',[0.6 0.6 0.6],'FontSize',8,'HorizontalAlignment','center');
end

%% ═══════════════════════════════════════════════════════════════════
%  FIGURE 3 — SNR Heatmap Dashboard
%% ═══════════════════════════════════════════════════════════════════
fig3 = figure('Name','Wi-Fi Channel Heatmap','Color','k', ...
              'Position',[1340 500 560 880]);

% 2.4 GHz heatmap
ax3a = subplot(2,1,1);
set(ax3a,'Color','k','XColor','w','YColor','w');
snr24 = [r24.snr_db];
util24 = [r24.utilization];
data24 = [snr24; util24];
imagesc(ax3a, data24);
colormap(ax3a, hot);
cb = colorbar(ax3a); cb.Color = 'w';
set(ax3a, 'XTick',1:13, 'XTickLabel',arrayfun(@(x) sprintf('Ch%d',x), ch24_num,'UniformOutput',false), ...
    'YTick',[1 2], 'YTickLabel',{'SNR (dB)','Util (%)'},'FontSize',9);
title(ax3a,'2.4 GHz — SNR & Utilization Heatmap','Color','w','FontSize',11);
% Annotate values
for k = 1:13
    text(ax3a, k, 1, sprintf('%.0f', snr24(k)),  'HorizontalAlignment','center','Color','w','FontSize',8,'FontWeight','bold');
    text(ax3a, k, 2, sprintf('%.0f%%',util24(k)),'HorizontalAlignment','center','Color','w','FontSize',8,'FontWeight','bold');
end

% 5 GHz heatmap
ax3b = subplot(2,1,2);
set(ax3b,'Color','k','XColor','w','YColor','w');
snr5  = [r5.snr_db];
util5 = [r5.utilization];
data5 = [snr5; util5];
imagesc(ax3b, data5);
colormap(ax3b, hot);
cb2 = colorbar(ax3b); cb2.Color = 'w';
n5 = numel(ch5_num);
set(ax3b, 'XTick',1:n5, ...
    'XTickLabel',arrayfun(@(x) sprintf('%d',x), ch5_num,'UniformOutput',false), ...
    'YTick',[1 2],'YTickLabel',{'SNR (dB)','Util (%)'},'FontSize',7);
xtickangle(ax3b,60);
title(ax3b,'5 GHz — SNR & Utilization Heatmap','Color','w','FontSize',11);
for k = 1:n5
    text(ax3b, k, 1, sprintf('%.0f', snr5(k)),  'HorizontalAlignment','center','Color','w','FontSize',7,'FontWeight','bold');
    text(ax3b, k, 2, sprintf('%.0f%%',util5(k)),'HorizontalAlignment','center','Color','w','FontSize',7,'FontWeight','bold');
end

%% ═══════════════════════════════════════════════════════════════════
%  FIGURE 4 — Critical Parameters Dashboard (bar charts)
%% ═══════════════════════════════════════════════════════════════════
fig4 = figure('Name','Critical Parameters Dashboard','Color','k', ...
              'Position',[1340 50 560 420]);

% SNR comparison — 2.4 GHz
ax4 = axes('Color','k','XColor','w','YColor','w');
hold(ax4,'on');

bar_colors24 = zeros(13,3);
for k = 1:13
    if r24(k).snr_db > 25;      bar_colors24(k,:) = [1.0 0.2 0.2];  % red  = very strong
    elseif r24(k).snr_db > 15;  bar_colors24(k,:) = [1.0 0.6 0.0];  % orange = strong
    elseif r24(k).snr_db > snr_threshold; bar_colors24(k,:) = [0.2 0.8 0.4]; % green = active
    else;                        bar_colors24(k,:) = [0.3 0.3 0.3];  % gray = clear
    end
end
b24 = bar(ax4, ch24_num, [r24.snr_db], 'FaceColor','flat');
b24.CData = bar_colors24;
yline(ax4, snr_threshold,'--','Color',[1 1 0.5],'LineWidth',1.5, ...
      'Label','Detection threshold','LabelHorizontalAlignment','right', ...
      'FontSize',9,'LabelColor',[1 1 0.5]);
xlabel(ax4,'2.4 GHz Channel','Color','w','FontSize',10);
ylabel(ax4,'SNR (dB)','Color','w','FontSize',10);
title(ax4,'2.4 GHz — Signal Strength per Channel','Color','w','FontSize',11,'FontWeight','bold');
set(ax4,'XTick',1:13); grid(ax4,'on'); ax4.GridColor=[0.2 0.2 0.2];

% Value labels on bars
for k = 1:13
    if r24(k).occupied
        text(ax4, k, r24(k).snr_db+0.5, sprintf('%.0f',r24(k).snr_db), ...
             'Color','w','FontSize',7,'HorizontalAlignment','center');
    end
end

%% ═══════════════════════════════════════════════════════════════════
%  FIGURE 5 — Summary Infographic
%% ═══════════════════════════════════════════════════════════════════
fig5 = figure('Name','Wi-Fi Environment Summary','Color','k', ...
              'Position',[680 50 640 880]);

% Panel layout: 4 subplots
% Top-left: 2.4G channel activity
ax5a = subplot(2,2,1);
set(ax5a,'Color','k','XColor','w','YColor','w');
pie_data24 = [active24, 13-active24];
if pie_data24(2) == 0; pie_data24(2) = 0.001; end
p24 = pie(ax5a, pie_data24);
p24(1).FaceColor = [1 0.3 0.3]; p24(1).EdgeColor = 'none';
p24(2).FaceColor = [0.2 0.5 0.2]; p24(2).EdgeColor = 'none';
p24(2).FaceAlpha = 0.5;
p24(3).Color = 'w'; p24(3).FontSize = 9;
p24(4).Color = 'w'; p24(4).FontSize = 9;
title(ax5a, sprintf('2.4 GHz Activity\n%d/%d channels',active24,13), ...
      'Color','w','FontSize',10);
legend(ax5a,{'Active','Clear'},'TextColor','w','Color','k','EdgeColor','w', ...
       'FontSize',8,'Location','southoutside');

% Top-right: 5G channel activity
ax5b = subplot(2,2,2);
set(ax5b,'Color','k','XColor','w','YColor','w');
pie_data5 = [active5, numel(ch5_num)-active5];
if pie_data5(2) == 0; pie_data5(2) = 0.001; end
p5 = pie(ax5b, pie_data5);
p5(1).FaceColor = [1 0.6 0.0]; p5(1).EdgeColor = 'none';
p5(2).FaceColor = [0.2 0.4 0.6]; p5(2).EdgeColor = 'none';
p5(2).FaceAlpha = 0.5;
p5(3).Color = 'w'; p5(3).FontSize = 9;
p5(4).Color = 'w'; p5(4).FontSize = 9;
title(ax5b, sprintf('5 GHz Activity\n%d/%d channels',active5,numel(ch5_num)), ...
      'Color','w','FontSize',10);
legend(ax5b,{'Active','Clear'},'TextColor','w','Color','k','EdgeColor','w', ...
       'FontSize',8,'Location','southoutside');

% Bottom-left: Noise floor comparison
ax5c = subplot(2,2,3);
set(ax5c,'Color','k','XColor','w','YColor','w');
bar_nf = bar(ax5c, [1 2], [noise24 noise5], 0.4, 'FaceColor','flat');
bar_nf.CData = [0.2 0.6 1.0; 1.0 0.6 0.2];
set(ax5c,'XTick',[1 2],'XTickLabel',{'2.4 GHz','5 GHz'});
ylabel(ax5c,'Noise Floor (dB)','Color','w');
title(ax5c,'Noise Floor Comparison','Color','w','FontSize',10);
text(ax5c,1,noise24+0.5,sprintf('%.1f dB',noise24),'Color','w','FontSize',10,'HorizontalAlignment','center','FontWeight','bold');
text(ax5c,2,noise5+0.5,sprintf('%.1f dB',noise5),'Color','w','FontSize',10,'HorizontalAlignment','center','FontWeight','bold');
grid(ax5c,'on'); ax5c.GridColor=[0.2 0.2 0.2]; ylim(ax5c,[min(noise24,noise5)-5 0]);

% Bottom-right: Top 5 strongest signals
ax5d = subplot(2,2,4);
set(ax5d,'Color','k','XColor','w','YColor','w');
all_snr    = [[r24.snr_db], [r5.snr_db]];
all_labels = [ch24_name, ch5_name];
all_occ    = [[r24.occupied], [r5.occupied]];
[sorted_snr, sort_idx] = sort(all_snr(all_occ==1), 'descend');
sorted_labels = all_labels(all_occ==1);
sorted_labels = sorted_labels(sort_idx);
n_top = min(8, numel(sorted_snr));
b_top = barh(ax5d, 1:n_top, sorted_snr(1:n_top), 'FaceColor','flat');
cmap_top = hot(n_top+2);
b_top.CData = cmap_top(1:n_top,:);
set(ax5d,'YTick',1:n_top,'YTickLabel',sorted_labels(1:n_top));
xlabel(ax5d,'SNR (dB)','Color','w');
title(ax5d,'Top Signals by SNR','Color','w','FontSize',10);
for k = 1:n_top
    text(ax5d, sorted_snr(k)+0.3, k, sprintf('%.1f',sorted_snr(k)), ...
         'Color','w','FontSize',8,'VerticalAlignment','middle');
end
grid(ax5d,'on'); ax5d.GridColor=[0.2 0.2 0.2];

sgtitle(fig5, sprintf('Wi-Fi Environment Summary  |  Scanned %s', datestr(now,'HH:MM dd-mmm-yyyy')), ...
        'Color','w','FontSize',12,'FontWeight','bold');

%% ═══════════════════════════════════════════════════════════════════
%  FINAL CONSOLE SUMMARY
%% ═══════════════════════════════════════════════════════════════════
fprintf('╔══════════════════════════════════════════════════════════════════╗\n');
fprintf('║                    SCAN COMPLETE                                 ║\n');
fprintf('╠══════════════════════════════════════════════════════════════════╣\n');
fprintf('║  5 figures generated:                                            ║\n');
fprintf('║   Fig 1 — 2.4 GHz full band spectrum overlay                     ║\n');
fprintf('║   Fig 2 — 5 GHz full band spectrum overlay                       ║\n');
fprintf('║   Fig 3 — SNR + utilization heatmap (both bands)                 ║\n');
fprintf('║   Fig 4 — Channel SNR bar chart (2.4 GHz)                        ║\n');
fprintf('║   Fig 5 — Summary dashboard (pie + noise + top signals)          ║\n');
fprintf('╠══════════════════════════════════════════════════════════════════╣\n');
fprintf('║  RECOMMENDATION:                                                  ║\n');
if active24 == 13
fprintf('║  2.4 GHz fully saturated — consider 5 GHz only devices           ║\n');
end
if active5 < 5
fprintf('║  5 GHz has clear channels — good for high-throughput devices      ║\n');
end
fprintf('╚══════════════════════════════════════════════════════════════════╝\n');
