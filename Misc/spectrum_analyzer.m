%% ============================================================
%  PlutoSDR — Real-Time Spectrum Analyzer
%  Full tuning range: 70 MHz – 6 GHz
%  Eye-candy GUI with waterfall, peak hold, signal markers
%
%  Controls:
%    Frequency slider  — 70 MHz to 6 GHz
%    Bandwidth slider  — 1 MHz to 56 MHz
%    Gain slider       — 0 to 73 dB
%    Peak Hold toggle  — latches maximum spectrum
%    Markers           — click spectrum to drop frequency marker
%    Ref Level         — adjusts Y axis
% ============================================================

function pluto_spectrum_analyzer()

clc;

%% ── PlutoSDR limits ─────────────────────────────────────────
FREQ_MIN    = 70e6;       % 70 MHz  (AD9364 unlocked)
FREQ_MAX    = 6e9;        % 6 GHz
SR_MIN      = 1e6;        % 1 MSPS
SR_MAX      = 56e6;       % 56 MSPS (max with AD9364 unlock)
GAIN_MIN    = 0;
GAIN_MAX    = 73;
FFT_SIZE    = 4096;
WATERFALL_LINES = 120;    % rows in waterfall history

%% ── State ───────────────────────────────────────────────────
state.freq       = 100e6;
state.sr         = 20e6;
state.gain       = 50;
state.ref_level  = 0;
state.peak_hold  = false;
state.peak_buf   = -120 * ones(1, FFT_SIZE);
state.waterfall  = -120 * ones(WATERFALL_LINES, FFT_SIZE);
state.running    = true;
state.rx         = [];
state.markers    = [];    % [freq_hz, power_db]
state.frame_count = 0;
state.fps_timer  = tic;
state.fps        = 0;
state.band_label = '';

%% ── Connect PlutoSDR ────────────────────────────────────────
fprintf('Connecting to PlutoSDR...\n');
connected = false;
for attempt = 1:2
    try
        rid = 'ip:192.168.2.1';
        if attempt == 2; rid = 'usb:0'; end
        state.rx = sdrrx('Pluto', ...
            'RadioID',            rid, ...
            'CenterFrequency',    state.freq, ...
            'BasebandSampleRate', state.sr, ...
            'SamplesPerFrame',    FFT_SIZE * 4, ...
            'GainSource',         'Manual', ...
            'Gain',               state.gain, ...
            'OutputDataType',     'double');
        fprintf('✓ Connected via %s\n', rid);
        connected = true;
        break;
    catch e
        fprintf('✗ %s : %s\n', rid, e.message);
    end
end
if ~connected
    error('PlutoSDR not found.');
end

% Warm up
try; step(state.rx); catch; end

%% ── Build GUI ───────────────────────────────────────────────
fig = uifigure('Name', 'PlutoSDR Spectrum Analyzer', ...
               'Position', [10 10 1600 950], ...
               'Color', [0.06 0.06 0.08], ...
               'Resize', 'on');
fig.DeleteFcn = @(~,~) cleanup();

% ── Color palette ────────────────────────────────────────────
C.bg       = [0.06 0.06 0.08];
C.panel    = [0.10 0.10 0.13];
C.border   = [0.20 0.20 0.25];
C.text     = [0.92 0.92 0.95];
C.accent   = [0.15 0.75 1.00];
C.green    = [0.20 1.00 0.50];
C.red      = [1.00 0.25 0.25];
C.yellow   = [1.00 0.85 0.10];
C.orange   = [1.00 0.55 0.10];
C.spectrum = [0.15 0.75 1.00];
C.peak     = [1.00 0.30 0.30];
C.grid     = [0.18 0.18 0.22];

%% ── LEFT CONTROL PANEL (200px) ──────────────────────────────
ctrl = uipanel(fig, 'Position',[5 5 210 940], ...
               'BackgroundColor', C.panel, ...
               'BorderType','none');

yc = 910;  % cursor from top of panel, working downward
function y = cy(h); yc = yc - h - 6; y = yc; end

% Title
uilabel(ctrl,'Text','PLUTO SDR','Position',[10 cy(28) 190 28], ...
        'FontSize',16,'FontWeight','bold', ...
        'FontColor',C.accent,'HorizontalAlignment','center', ...
        'BackgroundColor','none');
uilabel(ctrl,'Text','Spectrum Analyzer','Position',[10 cy(16) 190 16], ...
        'FontSize',10,'FontColor',[0.6 0.6 0.7], ...
        'HorizontalAlignment','center','BackgroundColor','none');
cy(6);

% ── Frequency ────────────────────────────────────────────────
uilabel(ctrl,'Text','CENTER FREQUENCY','Position',[10 cy(16) 190 16], ...
        'FontSize',9,'FontColor',[0.5 0.7 0.9],'BackgroundColor','none');
lbl_freq = uilabel(ctrl,'Text','100.000 MHz','Position',[10 cy(22) 190 22], ...
        'FontSize',15,'FontWeight','bold','FontColor',C.accent, ...
        'HorizontalAlignment','center','BackgroundColor','none');
sld_freq = uislider(ctrl,'Position',[10 cy(18) 190 18], ...
        'Limits',[log10(FREQ_MIN) log10(FREQ_MAX)], ...
        'Value', log10(state.freq));
sld_freq.ValueChangedFcn = @cb_freq;
% Freq input box
ef_freq = uieditfield(ctrl,'numeric', ...
        'Position',[10 cy(26) 140 26], ...
        'Value', state.freq/1e6, ...
        'Limits',[70 6000], ...
        'FontSize',11,'FontColor',C.text, ...
        'BackgroundColor',[0.14 0.14 0.18]);
uilabel(ctrl,'Text','MHz','Position',[155 yc 40 26], ...
        'FontSize',11,'FontColor',[0.6 0.6 0.7],'BackgroundColor','none');
ef_freq.ValueChangedFcn = @cb_freq_box;
cy(4);

% Band quick-select buttons
uilabel(ctrl,'Text','QUICK BANDS','Position',[10 cy(14) 190 14], ...
        'FontSize',8,'FontColor',[0.5 0.5 0.6],'BackgroundColor','none');
bands = {'FM','88M'; 'ADS-B','1090M'; 'GSM','900M'; ...
         'WiFi','2412M'; 'BT','2441M'; '5G','5180M'};
bx = 10; bw = 58; brow = cy(24);
for bi = 1:6
    col = mod(bi-1,3)*64 + 10;
    rw  = brow - floor((bi-1)/3)*28;
    uibutton(ctrl,'push','Text',bands{bi,1}, ...
        'Position',[col rw bw 22], ...
        'BackgroundColor',[0.16 0.22 0.30], ...
        'FontColor',C.accent,'FontSize',8, ...
        'ButtonPushedFcn', @(~,~) jump_band(bands{bi,2}));
end
cy(28); cy(6);

% ── Bandwidth ────────────────────────────────────────────────
uilabel(ctrl,'Text','BANDWIDTH','Position',[10 cy(14) 190 14], ...
        'FontSize',9,'FontColor',[0.5 0.7 0.9],'BackgroundColor','none');
lbl_bw = uilabel(ctrl,'Text','20.0 MHz','Position',[10 cy(20) 190 20], ...
        'FontSize',13,'FontWeight','bold','FontColor',C.green, ...
        'HorizontalAlignment','center','BackgroundColor','none');
sld_bw = uislider(ctrl,'Position',[10 cy(18) 190 18], ...
        'Limits',[1 56],'Value',20);
sld_bw.ValueChangedFcn = @cb_bw;
cy(6);

% ── Gain ─────────────────────────────────────────────────────
uilabel(ctrl,'Text','RX GAIN','Position',[10 cy(14) 190 14], ...
        'FontSize',9,'FontColor',[0.5 0.7 0.9],'BackgroundColor','none');
lbl_gain = uilabel(ctrl,'Text','50 dB','Position',[10 cy(20) 190 20], ...
        'FontSize',13,'FontWeight','bold','FontColor',C.yellow, ...
        'HorizontalAlignment','center','BackgroundColor','none');
sld_gain = uislider(ctrl,'Position',[10 cy(18) 190 18], ...
        'Limits',[GAIN_MIN GAIN_MAX],'Value',state.gain);
sld_gain.ValueChangedFcn = @cb_gain;
cy(6);

% ── Ref Level ────────────────────────────────────────────────
uilabel(ctrl,'Text','REF LEVEL (dB)','Position',[10 cy(14) 190 14], ...
        'FontSize',9,'FontColor',[0.5 0.7 0.9],'BackgroundColor','none');
lbl_ref = uilabel(ctrl,'Text','0 dB','Position',[10 cy(20) 190 20], ...
        'FontSize',13,'FontWeight','bold','FontColor',[0.8 0.8 0.8], ...
        'HorizontalAlignment','center','BackgroundColor','none');
sld_ref = uislider(ctrl,'Position',[10 cy(18) 190 18], ...
        'Limits',[-60 40],'Value',0);
sld_ref.ValueChangedFcn = @cb_ref;
cy(8);

% ── Toggles ──────────────────────────────────────────────────
btn_peak = uibutton(ctrl,'state','Text','⬛  PEAK HOLD OFF', ...
        'Position',[10 cy(28) 190 28], ...
        'Value',false, ...
        'BackgroundColor',[0.16 0.16 0.20], ...
        'FontColor',[0.5 0.5 0.6],'FontSize',10, ...
        'ValueChangedFcn',@cb_peak);
btn_clear = uibutton(ctrl,'push','Text','↺  CLEAR PEAK', ...
        'Position',[10 cy(24) 190 24], ...
        'BackgroundColor',[0.14 0.18 0.14], ...
        'FontColor',C.green,'FontSize',10, ...
        'ButtonPushedFcn',@cb_clear_peak);
cy(6);

btn_marker = uibutton(ctrl,'push','Text','◆  ADD MARKER', ...
        'Position',[10 cy(24) 90 24], ...
        'BackgroundColor',[0.18 0.14 0.20], ...
        'FontColor',[0.8 0.5 1.0],'FontSize',9, ...
        'ButtonPushedFcn',@cb_add_marker);
btn_clrmark = uibutton(ctrl,'push','Text','✕  CLEAR', ...
        'Position',[108 yc 92 24], ...
        'BackgroundColor',[0.20 0.14 0.14], ...
        'FontColor',C.red,'FontSize',9, ...
        'ButtonPushedFcn',@cb_clear_markers);
cy(8);

% ── Metrics readouts ─────────────────────────────────────────
uilabel(ctrl,'Text','─── LIVE METRICS ───','Position',[10 cy(14) 190 14], ...
        'FontSize',8,'FontColor',[0.35 0.35 0.45],'HorizontalAlignment','center', ...
        'BackgroundColor','none');

metric_fields = {'PEAK','NOISE FLOOR','SNR','BANDWIDTH','FPS','OVERFLOW'};
metric_colors = {C.red, [0.5 0.8 0.5], C.yellow, C.green, C.accent, C.orange};
lbl_metrics = cell(1,6);
for mi = 1:6
    uilabel(ctrl,'Text',metric_fields{mi},'Position',[10 cy(12) 100 12], ...
            'FontSize',8,'FontColor',[0.45 0.45 0.55],'BackgroundColor','none');
    lbl_metrics{mi} = uilabel(ctrl,'Text','—', ...
            'Position',[10 cy(16) 190 16], ...
            'FontSize',11,'FontWeight','bold', ...
            'FontColor',metric_colors{mi},'BackgroundColor','none');
    cy(2);
end
cy(4);

% ── Band label ───────────────────────────────────────────────
lbl_band = uilabel(ctrl,'Text','', ...
        'Position',[10 cy(22) 190 22], ...
        'FontSize',11,'FontWeight','bold', ...
        'FontColor',C.orange,'HorizontalAlignment','center', ...
        'BackgroundColor','none');

%% ── RIGHT PLOTS AREA ────────────────────────────────────────
% Spectrum plot (top 55%)
ax_spec = uiaxes(fig,'Position',[225 380 1365 555]);
set_ax_dark(ax_spec, C);
ax_spec.XLabel.String = 'Frequency';
ax_spec.YLabel.String = 'Power (dB)';
ax_spec.Title.String  = 'Real-Time Spectrum';
ax_spec.Title.Color   = C.accent;
ax_spec.Title.FontSize = 13;
hold(ax_spec,'on');

% Pre-build plot objects
f_axis = linspace(-state.sr/2, state.sr/2, FFT_SIZE) + state.freq;
h_fill   = fill(ax_spec, [f_axis, fliplr(f_axis)]/1e6, ...
                [-120*ones(1,FFT_SIZE), -120*ones(1,FFT_SIZE)], ...
                C.spectrum, 'FaceAlpha',0.15, 'EdgeColor','none');
h_spec   = plot(ax_spec, f_axis/1e6, -120*ones(1,FFT_SIZE), ...
                'Color',C.spectrum,'LineWidth',1.2);
h_peak   = plot(ax_spec, f_axis/1e6, -120*ones(1,FFT_SIZE), ...
                'Color',C.peak,'LineWidth',0.8,'LineStyle','--');
h_noise  = yline(ax_spec, -120, '--', 'Color',[0.4 0.4 0.5 0.6], ...
                 'LineWidth',0.8);

ax_spec.ButtonDownFcn = @cb_spec_click;

% Waterfall (bottom 30%)
ax_wf = uiaxes(fig,'Position',[225 5 1365 365]);
set_ax_dark(ax_wf, C);
ax_wf.XLabel.String = 'Frequency (MHz)';
ax_wf.YLabel.String = 'Time →';
ax_wf.Title.String  = 'Waterfall';
ax_wf.Title.Color   = [0.5 0.7 0.9];
ax_wf.YTick = [];

h_wf = imagesc(ax_wf, f_axis/1e6, 1:WATERFALL_LINES, state.waterfall);
colormap(ax_wf, custom_colormap());
clim(ax_wf, [-90 0]);
ax_wf.YDir = 'reverse';

%% ── Timer — main loop ───────────────────────────────────────
t = timer('ExecutionMode','fixedRate','Period',0.04, ...  % ~25 fps target
          'TimerFcn',@update_loop, ...
          'ErrorFcn',@timer_error);
start(t);

%% ════════════════════════════════════════════════════════════
%  CALLBACKS
%% ════════════════════════════════════════════════════════════

    function cb_freq(src,~)
        new_f = 10^src.Value;
        new_f = round(new_f / 1e3) * 1e3;
        new_f = max(FREQ_MIN, min(FREQ_MAX, new_f));
        state.freq = new_f;
        lbl_freq.Text = fmt_freq(new_f);
        ef_freq.Value = new_f/1e6;
        state.rx.CenterFrequency = new_f;
        state.peak_buf = -120*ones(1,FFT_SIZE);
        update_band_label(new_f);
    end

    function cb_freq_box(src,~)
        new_f = src.Value * 1e6;
        new_f = max(FREQ_MIN, min(FREQ_MAX, new_f));
        state.freq = new_f;
        sld_freq.Value = log10(new_f);
        lbl_freq.Text  = fmt_freq(new_f);
        state.rx.CenterFrequency = new_f;
        state.peak_buf = -120*ones(1,FFT_SIZE);
        update_band_label(new_f);
    end

    function cb_bw(src,~)
        bw_mhz = round(src.Value);
        bw_mhz = max(1, min(56, bw_mhz));
        % Snap to valid PlutoSDR sample rates
        valid_sr = [1 2 3 4 5 6 8 10 12 15 16 20 24 25 30 32 40 48 50 56];
        [~,vi] = min(abs(valid_sr - bw_mhz));
        bw_mhz = valid_sr(vi);
        src.Value = bw_mhz;
        state.sr = bw_mhz * 1e6;
        lbl_bw.Text = sprintf('%.0f MHz', bw_mhz);
        % Must release and recreate for SR change
        release(state.rx);
        state.rx.BasebandSampleRate = state.sr;
        state.rx.SamplesPerFrame    = FFT_SIZE * 4;
        state.peak_buf = -120*ones(1,FFT_SIZE);
        state.waterfall = -120*ones(WATERFALL_LINES, FFT_SIZE);
    end

    function cb_gain(src,~)
        state.gain = round(src.Value);
        lbl_gain.Text = sprintf('%d dB', state.gain);
        state.rx.Gain = state.gain;
    end

    function cb_ref(src,~)
        state.ref_level = src.Value;
        lbl_ref.Text = sprintf('%+.0f dB', state.ref_level);
    end

    function cb_peak(src,~)
        state.peak_hold = src.Value;
        if state.peak_hold
            src.Text = '🔴  PEAK HOLD ON';
            src.FontColor = C.red;
            src.BackgroundColor = [0.22 0.10 0.10];
        else
            src.Text = '⬛  PEAK HOLD OFF';
            src.FontColor = [0.5 0.5 0.6];
            src.BackgroundColor = [0.16 0.16 0.20];
        end
    end

    function cb_clear_peak(~,~)
        state.peak_buf = -120*ones(1,FFT_SIZE);
    end

    function cb_add_marker(~,~)
        % Add marker at current peak frequency
        [pk_val, pk_idx] = max(state.peak_buf);
        f_ax = linspace(-state.sr/2, state.sr/2, FFT_SIZE) + state.freq;
        pk_freq = f_ax(pk_idx);
        state.markers(end+1,:) = [pk_freq, pk_val];
    end

    function cb_clear_markers(~,~)
        state.markers = [];
        % Remove marker lines from spectrum
        delete(findobj(ax_spec,'Tag','marker'));
    end

    function cb_spec_click(~, evt)
        click_f_mhz = evt.IntersectionPoint(1);
        click_f_hz  = click_f_mhz * 1e6;
        click_f_hz  = max(FREQ_MIN, min(FREQ_MAX, click_f_hz));
        state.freq  = click_f_hz;
        sld_freq.Value = log10(click_f_hz);
        lbl_freq.Text  = fmt_freq(click_f_hz);
        ef_freq.Value  = click_f_hz/1e6;
        state.rx.CenterFrequency = click_f_hz;
        state.peak_buf = -120*ones(1,FFT_SIZE);
        update_band_label(click_f_hz);
    end

%% ════════════════════════════════════════════════════════════
%  MAIN UPDATE LOOP
%% ════════════════════════════════════════════════════════════
    function update_loop(~,~)
        if ~state.running || ~isvalid(fig); return; end

        %% Capture samples
        overflow = false;
        try
            [samples, ~, overflow] = step(state.rx);
        catch
            return;
        end

        %% Welch PSD — average 4 sub-frames
        n_sub  = 4;
        sublen = floor(length(samples)/n_sub);
        if sublen < FFT_SIZE; sublen = FFT_SIZE; n_sub = 1; end
        win    = hann(FFT_SIZE);
        psd    = zeros(FFT_SIZE,1);
        for s = 1:n_sub
            seg  = samples((s-1)*sublen+1 : (s-1)*sublen+FFT_SIZE);
            S    = fftshift(fft(seg .* win, FFT_SIZE));
            psd  = psd + abs(S).^2;
        end
        psd    = psd / n_sub;
        psd_db = 10*log10(psd/FFT_SIZE + eps) + state.ref_level;

        %% Peak hold
        if state.peak_hold
            state.peak_buf = max(state.peak_buf, psd_db');
        else
            state.peak_buf = psd_db';
        end

        %% Metrics
        noise_floor = median(psd_db);
        peak_val    = max(psd_db);
        snr_val     = peak_val - noise_floor;

        thresh = noise_floor + 6;
        f_ax   = linspace(-state.sr/2, state.sr/2, FFT_SIZE) + state.freq;
        active = f_ax(psd_db' > thresh);
        if ~isempty(active)
            est_bw = (max(active)-min(active))/1e6;
        else
            est_bw = 0;
        end

        %% FPS
        state.frame_count = state.frame_count + 1;
        elapsed = toc(state.fps_timer);
        if elapsed >= 1.0
            state.fps = state.frame_count / elapsed;
            state.frame_count = 0;
            state.fps_timer = tic;
        end

        %% Waterfall scroll
        state.waterfall = [psd_db'; state.waterfall(1:end-1,:)];

        %% ── Update plots ────────────────────────────────────
        f_mhz = f_ax / 1e6;

        % Spectrum line + fill
        set(h_spec, 'XData', f_mhz, 'YData', psd_db);
        set(h_fill, 'XData', [f_mhz, fliplr(f_mhz)], ...
                    'YData', [psd_db', (noise_floor)*ones(1,FFT_SIZE)]);

        % Peak hold line
        set(h_peak, 'XData', f_mhz, 'YData', state.peak_buf);
        h_peak.Visible = onoff(state.peak_hold);

        % Noise floor line
        h_noise.Value = noise_floor;

        % Axes limits
        y_floor = noise_floor - 10;
        y_top   = state.ref_level + 15;
        ylim(ax_spec, [y_floor y_top]);
        xlim(ax_spec, [f_mhz(1) f_mhz(end)]);

        % Dynamic title
        ax_spec.Title.String = sprintf('%.6f %s  |  BW: %.0f MHz  |  SNR: %.1f dB  |  Peak: %.1f dB', ...
            freq_val(state.freq), freq_unit(state.freq), state.sr/1e6, snr_val, peak_val);

        % Waterfall
        set(h_wf, 'XData', f_mhz, 'CData', state.waterfall);
        xlim(ax_wf, [f_mhz(1) f_mhz(end)]);
        clim(ax_wf, [noise_floor-5, noise_floor+max(30,snr_val+5)]);

        % Markers
        delete(findobj(ax_spec,'Tag','marker'));
        delete(findobj(ax_spec,'Tag','marker_txt'));
        for mk = 1:size(state.markers,1)
            mf = state.markers(mk,1)/1e6;
            mp = state.markers(mk,2);
            xline(ax_spec, mf, 'Color',[0.8 0.5 1.0 0.8], ...
                  'LineWidth',1.2,'Tag','marker');
            text(ax_spec, mf, y_top-2, ...
                 sprintf('M%d\n%.3f\n%.1fdB',mk,mf,mp), ...
                 'Color',[0.8 0.5 1.0],'FontSize',7, ...
                 'HorizontalAlignment','center','Tag','marker_txt');
        end

        % Peak dot
        [~,pi_] = max(psd_db);
        delete(findobj(ax_spec,'Tag','peak_dot'));
        plot(ax_spec, f_mhz(pi_), psd_db(pi_), 'o', ...
             'Color',C.red,'MarkerFaceColor',C.red, ...
             'MarkerSize',6,'Tag','peak_dot');
        delete(findobj(ax_spec,'Tag','peak_lbl'));
        text(ax_spec, f_mhz(pi_), psd_db(pi_)+1.5, ...
             sprintf('%.3f %s', freq_val(f_ax(pi_)), freq_unit(f_ax(pi_))), ...
             'Color',C.red,'FontSize',8,'HorizontalAlignment','center', ...
             'Tag','peak_lbl');

        %% ── Update metric labels ────────────────────────────
        lbl_metrics{1}.Text = sprintf('%.1f dB', peak_val);
        lbl_metrics{2}.Text = sprintf('%.1f dB', noise_floor);
        lbl_metrics{3}.Text = sprintf('%.1f dB', snr_val);
        lbl_metrics{4}.Text = sprintf('%.1f MHz', est_bw);
        lbl_metrics{5}.Text = sprintf('%.1f fps', state.fps);
        lbl_metrics{6}.Text = ternary(overflow,'⚠ YES','OK');
        lbl_metrics{6}.FontColor = ternary(overflow, C.orange, C.green);

        drawnow limitrate;
    end

%% ════════════════════════════════════════════════════════════
%  HELPERS
%% ════════════════════════════════════════════════════════════
    function update_band_label(f)
        bands_db = {
            [87.5e6,  108e6],  'FM Broadcast';
            [108e6,   137e6],  'VHF Aviation';
            [137e6,   174e6],  'VHF / NOAA';
            [174e6,   230e6],  'VHF-III TV';
            [380e6,   400e6],  'TETRA';
            [433e6,   435e6],  'ISM 433 MHz';
            [450e6,   470e6],  'UHF Land Mobile';
            [470e6,   790e6],  'UHF TV / DTT';
            [790e6,   862e6],  '4G Band 20';
            [869e6,   894e6],  'GSM-900 DL';
            [880e6,   915e6],  'GSM-900 UL';
            [1090e6, 1090e6],  'ADS-B (Aircraft)';
            [1176e6, 1227e6],  'GPS L5/L2';
            [1559e6, 1610e6],  'GPS L1 / GNSS';
            [1710e6, 1785e6],  'LTE Band 3 UL';
            [1805e6, 1880e6],  'LTE Band 3 DL';
            [2100e6, 2170e6],  'LTE Band 1 DL';
            [2300e6, 2400e6],  'LTE Band 40 (Jio)';
            [2400e6, 2484e6],  'Wi-Fi 2.4 GHz';
            [2400e6, 2484e6],  'Bluetooth 2.4 GHz';
            [3300e6, 3600e6],  '5G NR n78';
            [5150e6, 5850e6],  'Wi-Fi 5 GHz';
        };
        lbl_band.Text = '';
        for bi = 1:size(bands_db,1)
            if f >= bands_db{bi,1}(1) && f <= bands_db{bi,1}(end)
                lbl_band.Text = bands_db{bi,2};
                break;
            end
        end
    end

    function jump_band(tag)
        freq_map = struct('FM','88e6','ADSB','1090e6','GSM','935e6', ...
                          'WiFi','2437e6','BT','2441e6','v5G','5180e6');
        val = str2double(strrep(tag,'M','')) * 1e6;
        val = max(FREQ_MIN, min(FREQ_MAX, val));
        state.freq = val;
        sld_freq.Value = log10(val);
        lbl_freq.Text  = fmt_freq(val);
        ef_freq.Value  = val/1e6;
        state.rx.CenterFrequency = val;
        state.peak_buf = -120*ones(1,FFT_SIZE);
        update_band_label(val);
    end

    function cleanup()
        state.running = false;
        try; stop(t); delete(t); catch; end
        try; release(state.rx); fprintf('PlutoSDR released.\n'); catch; end
    end

    function timer_error(~,evt)
        fprintf('Timer error: %s\n', evt.Data.message);
    end

    function set_ax_dark(ax, C)
        ax.Color      = C.bg;
        ax.XColor     = [0.55 0.60 0.65];
        ax.YColor     = [0.55 0.60 0.65];
        ax.XGrid      = 'on';
        ax.YGrid      = 'on';
        ax.FontSize   = 9;
        ax.Box        = 'on';
        ax.LineWidth  = 0.8;
        ax.Title.FontSize  = 11;
        ax.Title.Color     = C.accent;
        ax.XLabel.FontSize = 10;
        ax.YLabel.FontSize = 10;
    end

    function cmap = custom_colormap()
        % Jet-inspired dark waterfall: black→purple→blue→cyan→green→yellow→red
        n = 256;
        cmap = zeros(n,3);
        % Black to deep blue (0-60)
        cmap(1:60,1)  = 0;
        cmap(1:60,2)  = 0;
        cmap(1:60,3)  = linspace(0, 0.5, 60);
        % Deep blue to cyan (60-100)
        cmap(60:100,1) = 0;
        cmap(60:100,2) = linspace(0, 0.8, 41);
        cmap(60:100,3) = linspace(0.5, 1.0, 41);
        % Cyan to green (100-150)
        cmap(100:150,1) = 0;
        cmap(100:150,2) = linspace(0.8, 1.0, 51);
        cmap(100:150,3) = linspace(1.0, 0.0, 51);
        % Green to yellow (150-200)
        cmap(150:200,1) = linspace(0.0, 1.0, 51);
        cmap(150:200,2) = 1.0;
        cmap(150:200,3) = 0;
        % Yellow to red (200-256)
        cmap(200:256,1) = 1.0;
        cmap(200:256,2) = linspace(1.0, 0.0, 57);
        cmap(200:256,3) = 0;
    end

    function s = fmt_freq(f)
        if f >= 1e9
            s = sprintf('%.6f GHz', f/1e9);
        elseif f >= 1e6
            s = sprintf('%.4f MHz', f/1e6);
        else
            s = sprintf('%.1f kHz', f/1e3);
        end
    end

    function v = freq_val(f)
        if f >= 1e9;     v = f/1e9;
        elseif f >= 1e6; v = f/1e6;
        else;            v = f/1e3; end
    end

    function u = freq_unit(f)
        if f >= 1e9;     u = 'GHz';
        elseif f >= 1e6; u = 'MHz';
        else;            u = 'kHz'; end
    end

    function s = onoff(v)
        if v; s = 'on'; else; s = 'off'; end
    end

    function r = ternary(cond, a, b)
        if cond; r = a; else; r = b; end
    end

end
