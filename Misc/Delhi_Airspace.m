%% ADALM PlutoSDR — ADS-B Aircraft Tracker
% Receives 1090 MHz ADS-B signals, decodes Mode-S messages,
% extracts ICAO, callsign, position, altitude, speed and plots live map
%
% What you'll see: Every aircraft overhead broadcasting its GPS position,
% altitude, speed, callsign — updated in real time
%
% LEGAL: Pure receive. ADS-B is publicly broadcast by every commercial
%        aircraft. This is exactly how Flightradar24 works.
%
% Requirements:
%   - Communications Toolbox
%   - ADALM-Pluto Support Package
%   - NO Mapping Toolbox needed — uses basic MATLAB plotting

clc; clear; close all;

%% ============================================================
%  PARAMETERS
%% ============================================================
fc          = 1090e6;      % ADS-B frequency (worldwide standard)
fs          = 12e6;        % 12 MHz — PlutoSDR native ADS-B rate
rx_gain     = 40;          % dB — increase if few planes detected
frame_ms    = 100;         % Capture 100ms per batch (fits ~800 messages)
frame_samps = round(fs * frame_ms / 1e3);  % 1,200,000 samples
pluto_uri   = 'ip:192.168.2.1';

% ADS-B timing at 12 MHz (12 samples per microsecond)
SPS         = 12;          % samples per microsecond
PREAMBLE_US = 8;           % preamble duration
BIT_US      = 1;           % 1 bit = 1 microsecond = 12 samples
SHORT_MSG   = 56;          % short squitter: 56 bits
LONG_MSG    = 112;         % extended squitter: 112 bits (has position)
PREAMBLE_SAMPS = PREAMBLE_US * SPS;  % 96 samples

% Preamble pattern at 12 MHz (pulses at 0,1,3.5,4.5 µs)
% Each bit = 12 samples, pulse = first 6 samples high
preamble_template = zeros(1, PREAMBLE_SAMPS);
preamble_template(1:6)   = 1;   % pulse at 0 µs
preamble_template(13:18) = 1;   % pulse at 1 µs
preamble_template(43:48) = 1;   % pulse at 3.5 µs
preamble_template(55:60) = 1;   % pulse at 4.5 µs

fprintf('=== PlutoSDR ADS-B Aircraft Tracker ===\n');
fprintf('Frequency  : %.0f MHz\n', fc/1e6);
fprintf('Sample rate: %.0f MHz\n', fs/1e6);
fprintf('Frame size : %d ms (%d samples)\n', frame_ms, frame_samps);
fprintf('Gain       : %d dB\n\n', rx_gain);

%% ============================================================
%  CONNECT PLUTO
%% ============================================================
fprintf('Connecting to PlutoSDR...\n');
try
    rx = sdrrx('Pluto', ...
        'RadioID',            pluto_uri, ...
        'CenterFrequency',    fc, ...
        'BasebandSampleRate', fs, ...
        'GainSource',         'Manual', ...
        'Gain',               rx_gain, ...
        'OutputDataType',     'double', ...
        'SamplesPerFrame',    frame_samps);
catch
    fprintf('IP failed, trying USB...\n');
    rx = sdrrx('Pluto', ...
        'RadioID',            'usb:0', ...
        'CenterFrequency',    fc, ...
        'BasebandSampleRate', fs, ...
        'GainSource',         'Manual', ...
        'Gain',               rx_gain, ...
        'OutputDataType',     'double', ...
        'SamplesPerFrame',    frame_samps);
end
fprintf('PlutoSDR connected!\n\n');

%% ============================================================
%  AIRCRAFT DATABASE
%% ============================================================
aircraft = struct();  % keyed by ICAO hex

%% ============================================================
%  SETUP LIVE PLOT
%% ============================================================
fig = figure('Name','ADS-B Aircraft Tracker — Delhi NCR', ...
             'Color','black','Position',[50 50 1400 800]);

% Map axes
ax_map = subplot(1,2,1);
set(ax_map,'Color',[0.05 0.05 0.1],'XColor','w','YColor','w');
hold(ax_map,'on');
title(ax_map,'Live Aircraft Map — Delhi NCR','Color','w','FontSize',13);
xlabel(ax_map,'Longitude','Color','w');
ylabel(ax_map,'Latitude','Color','w');
grid(ax_map,'on'); ax_map.GridColor = [0.2 0.2 0.3];

% Delhi NCR bounds
delhi_lat = [28.2, 29.0];
delhi_lon = [76.6, 77.6];
xlim(ax_map, delhi_lon);
ylim(ax_map, delhi_lat);

% Draw Delhi reference point
plot(ax_map, 77.1025, 28.7041, 'r+', 'MarkerSize',12,'LineWidth',2);
text(ax_map, 77.1025, 28.68, 'Delhi','Color','r','FontSize',9,'HorizontalAlignment','center');

% Table axes
ax_tbl = subplot(1,2,2);
set(ax_tbl,'Color',[0.03 0.03 0.06],'Visible','off');
title(ax_tbl,'Aircraft Data','Color','w','FontSize',13);

fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║           ADS-B TRACKER RUNNING — LOOK UP!                  ║\n');
fprintf('║   Every plane overhead is broadcasting its GPS position.    ║\n');
fprintf('║   Press Ctrl+C to stop.                                     ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n\n');
fprintf('%-8s %-10s %-8s %-8s %-8s %-8s\n', ...
        'ICAO','Callsign','Lat','Lon','Alt(ft)','Spd(kt)');
fprintf('%s\n', repmat('-',1,60));

%% ============================================================
%  CRC CHECK for Mode-S
%% ============================================================
function ok = crc24(bits)
    % Mode-S CRC24 generator polynomial
    GENERATOR = [1 1 1 1 1 1 1 1 1 1 1 1 1 0 1 0 0 0 0 0 0 1 0 0 1];
    n = length(bits);
    msg = [bits(1:end-24), zeros(1,24)];
    for i = 1:n-24
        if msg(i) == 1
            msg(i:i+24) = xor(msg(i:i+24), GENERATOR);
        end
    end
    ok = all(msg(end-23:end) == bits(end-23:end));
end

%% ============================================================
%  CPR POSITION DECODE (Compact Position Reporting)
%% ============================================================
function [lat, lon] = decode_cpr(lat_even, lon_even, lat_odd, lon_odd, is_odd)
    % Simplified CPR decode — works when even+odd pair available
    NZ = 15;
    dlat_even = 360 / (4*NZ);
    dlat_odd  = 360 / (4*NZ - 1);

    j = floor(59*lat_even - 60*lat_odd + 0.5);
    lat_e = dlat_even * (mod(j, 60) + lat_even);
    lat_o = dlat_odd  * (mod(j, 59) + lat_odd);

    if lat_e >= 270; lat_e = lat_e - 360; end
    if lat_o >= 270; lat_o = lat_o - 360; end

    % NL function
    nl_e = nl_func(lat_e);
    nl_o = nl_func(lat_o);

    if nl_e ~= nl_o
        lat = NaN; lon = NaN;
        return;
    end

    if ~is_odd
        lat = lat_e;
        nl  = nl_e;
        dlon = 360 / max(nl, 1);
        m   = floor(lon_even*(nl-1) - lon_odd*nl + 0.5);
        lon = dlon * (mod(m, max(nl,1)) + lon_even);
    else
        lat = lat_o;
        nl  = max(nl_o - 1, 1);
        dlon = 360 / nl;
        m   = floor(lon_even*(nl) - lon_odd*(nl+1) + 0.5);  %#ok
        lon = dlon * (mod(m, nl) + lon_odd);
    end

    if lon >= 180; lon = lon - 360; end
end

function nl = nl_func(lat)
    if abs(lat) >= 87; nl = 1; return; end
    if abs(lat) == 0;  nl = 59; return; end
    nl = floor(2*pi / acos(1 - (1-cos(pi/(2*15))) / cos(pi*lat/180)^2));
end

%% ============================================================
%  MAIN RECEIVE & DECODE LOOP
%% ============================================================
frame_count = 0;
msg_count   = 0;
t_start     = tic;

% CPR buffers for position decode
cpr_buf = struct();

try
while true
    %% Capture IQ frame
    iq = rx();
    iq = iq(:);

    %% Envelope detect (ADS-B is AM/PPM — use magnitude)
    env = abs(iq);

    %% Normalize
    env = env / (max(env) + 1e-9);

    %% Noise floor estimate
    noise_floor = median(env);
    threshold   = noise_floor * 3.0;  % 3x noise = preamble detection

    %% Matched filter for preamble detection
    % Correlate with preamble template
    corr = conv(env, fliplr(preamble_template), 'valid');

    %% Find preamble peaks
    min_spacing = LONG_MSG * SPS + PREAMBLE_SAMPS;
    peak_thresh = max(corr) * 0.4;
    if peak_thresh < 0.1; frame_count = frame_count+1; continue; end

    % Find peaks with minimum spacing
    peaks = [];
    k = 1;
    while k <= length(corr)
        if corr(k) > peak_thresh
            [~, local_max] = max(corr(k:min(k+20, length(corr))));
            peaks(end+1) = k + local_max - 1; %#ok
            k = k + min_spacing;
        else
            k = k + 1;
        end
    end

    %% Decode each detected message
    for pi = 1:length(peaks)
        pstart = peaks(pi);

        % Try extended squitter first (112 bits)
        msg_start = pstart + PREAMBLE_SAMPS;
        msg_end   = msg_start + LONG_MSG * SPS - 1;
        if msg_end > length(env); continue; end

        % Extract bits via PPM demodulation
        % Each bit: compare first half vs second half of 12-sample window
        bits = zeros(1, LONG_MSG);
        valid = true;
        for b = 1:LONG_MSG
            s1 = msg_start + (b-1)*SPS;
            s2 = s1 + SPS/2;
            if s2 + SPS/2 - 1 > length(env); valid=false; break; end
            first_half  = mean(env(s1 : s1+SPS/2-1));
            second_half = mean(env(s2 : s2+SPS/2-1));
            if first_half > second_half
                bits(b) = 1;
            else
                bits(b) = 0;
            end
        end
        if ~valid; continue; end

        % CRC check
        if ~crc24(bits); continue; end

        %% Parse message fields
        % Downlink Format (DF) — first 5 bits
        df = bits2dec(bits(1:5));

        % Only process DF17 (ADS-B) and DF18 (TIS-B)
        if df ~= 17 && df ~= 18; continue; end

        % ICAO address (bits 9-32)
        icao_bits = bits(9:32);
        icao = dec2hex(bits2dec(icao_bits), 6);

        % Type Code (bits 33-37)
        tc = bits2dec(bits(33:37));

        % Initialize aircraft entry
        if ~isfield(aircraft, icao)
            aircraft.(icao).callsign = '????????';
            aircraft.(icao).lat      = NaN;
            aircraft.(icao).lon      = NaN;
            aircraft.(icao).alt      = NaN;
            aircraft.(icao).speed    = NaN;
            aircraft.(icao).heading  = NaN;
            aircraft.(icao).cpr_even = [];
            aircraft.(icao).cpr_odd  = [];
            aircraft.(icao).last_seen = toc(t_start);
        end
        aircraft.(icao).last_seen = toc(t_start);

        %% Decode by Type Code
        if tc >= 1 && tc <= 4
            %% Aircraft Identification (Callsign)
            charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ     0123456789      ';
            cs = '';
            for ci = 1:8
                idx = bits2dec(bits(40 + (ci-1)*6 : 45 + (ci-1)*6)) + 1;
                if idx <= length(charset)
                    cs = [cs charset(idx)]; %#ok
                end
            end
            aircraft.(icao).callsign = strtrim(cs);

        elseif tc >= 9 && tc <= 18
            %% Airborne Position
            % Altitude (bits 41-52, Gillham/Gray code)
            alt_bits = bits(41:52);
            q_bit = alt_bits(8);
            if q_bit == 1
                % 25ft resolution
                n = bits2dec([alt_bits(1:7), alt_bits(9:12)]);
                alt_ft = n * 25 - 1000;
                aircraft.(icao).alt = alt_ft;
            end

            % CPR position
            cpr_format = bits(54);  % 0=even, 1=odd
            lat_cpr = bits2dec(bits(55:71)) / 131072;
            lon_cpr = bits2dec(bits(72:88)) / 131072;

            if cpr_format == 0
                aircraft.(icao).cpr_even = [lat_cpr, lon_cpr];
            else
                aircraft.(icao).cpr_odd  = [lat_cpr, lon_cpr];
            end

            % Decode position if we have both even and odd
            if ~isempty(aircraft.(icao).cpr_even) && ~isempty(aircraft.(icao).cpr_odd)
                try
                    [lat, lon] = decode_cpr(...
                        aircraft.(icao).cpr_even(1), aircraft.(icao).cpr_even(2), ...
                        aircraft.(icao).cpr_odd(1),  aircraft.(icao).cpr_odd(2), ...
                        cpr_format);
                    if ~isnan(lat) && ~isnan(lon)
                        % Sanity check — Delhi region
                        if lat > 20 && lat < 40 && lon > 68 && lon < 88
                            aircraft.(icao).lat = lat;
                            aircraft.(icao).lon = lon;
                        end
                    end
                catch
                end
            end

        elseif tc == 19
            %% Airborne Velocity
            vtype = bits2dec(bits(38:40));
            if vtype == 1 || vtype == 2
                % Ground speed
                dew = bits(42);  % E-W direction
                vew = bits2dec(bits(43:52)) - 1;
                dns = bits(53);  % N-S direction
                vns = bits2dec(bits(54:63)) - 1;
                if dew; vew = -vew; end
                if dns; vns = -vns; end
                spd = sqrt(vew^2 + vns^2);
                hdg = mod(atan2(vew, vns)*180/pi, 360);
                aircraft.(icao).speed   = round(spd);
                aircraft.(icao).heading = round(hdg);
            end
        end

        msg_count = msg_count + 1;

        %% Print decoded message
        ac = aircraft.(icao);
        if ~isnan(ac.lat)
            fprintf('%-8s %-10s %-8.4f %-8.4f %-8.0f %-8.0f\n', ...
                    icao, ac.callsign, ac.lat, ac.lon, ...
                    ac.alt, ac.speed);
        end
    end

    frame_count = frame_count + 1;

    %% Update map every 5 frames
    if mod(frame_count, 5) == 0
        cla(ax_map);
        hold(ax_map, 'on');

        % Redraw Delhi marker
        plot(ax_map, 77.1025, 28.7041, 'r+', 'MarkerSize',12,'LineWidth',2);
        text(ax_map, 77.1025, 28.67, 'Delhi','Color','r','FontSize',8, ...
             'HorizontalAlignment','center');

        % Draw each aircraft
        icao_list = fieldnames(aircraft);
        n_active  = 0;
        tbl_str   = {};

        for ai = 1:length(icao_list)
            id  = icao_list{ai};
            ac  = aircraft.(id);
            age = toc(t_start) - ac.last_seen;
            if age > 60; continue; end  % remove stale >60s
            n_active = n_active + 1;

            if ~isnan(ac.lat) && ~isnan(ac.lon)
                % Aircraft symbol — triangle pointing in heading direction
                plot(ax_map, ac.lon, ac.lat, '^', ...
                     'Color', [0.2 0.8 1.0], ...
                     'MarkerFaceColor', [0.2 0.8 1.0], ...
                     'MarkerSize', 10);

                % Callsign label
                text(ax_map, ac.lon, ac.lat + 0.015, ...
                     sprintf('%s\n%.0fft', ac.callsign, ac.alt), ...
                     'Color','w','FontSize',7,'HorizontalAlignment','center');

                % Speed vector
                if ~isnan(ac.heading) && ~isnan(ac.speed)
                    hdg_rad = ac.heading * pi/180;
                    vec_len = 0.03;
                    plot(ax_map, ...
                         [ac.lon, ac.lon + vec_len*sin(hdg_rad)], ...
                         [ac.lat, ac.lat + vec_len*cos(hdg_rad)], ...
                         '-', 'Color',[0.5 1.0 0.5],'LineWidth',1.5);
                end

                tbl_str{end+1} = sprintf('%-8s %-10s %6.2f° %6.2f° %6.0fft %5.0fkt', ...
                    id, ac.callsign, ac.lat, ac.lon, ac.alt, ac.speed); %#ok
            else
                % No position yet — show as dot
                plot(ax_map, delhi_lon(1)+0.05*(mod(ai,8)), ...
                     delhi_lat(1)+0.05*floor(ai/8), '.', ...
                     'Color',[0.5 0.5 0.5],'MarkerSize',5);
            end
        end

        % Map styling
        set(ax_map,'Color',[0.05 0.05 0.1],'XColor','w','YColor','w');
        xlim(ax_map, delhi_lon); ylim(ax_map, delhi_lat);
        grid(ax_map,'on'); ax_map.GridColor = [0.15 0.15 0.25];
        title(ax_map, sprintf('Delhi NCR Airspace — %d aircraft | %d msgs | %.0fs', ...
              n_active, msg_count, toc(t_start)), 'Color','w','FontSize',11);

        % Text table on right panel
        cla(ax_tbl);
        set(ax_tbl,'Color',[0.03 0.03 0.06],'Visible','off');
        y_pos = 0.95;
        text(ax_tbl, 0.01, y_pos, 'ICAO    Callsign   Lat      Lon      Alt     Spd', ...
             'Color',[0.6 0.9 1.0],'FontSize',8,'FontName','Monospaced', ...
             'Units','normalized','Parent',ax_tbl);
        y_pos = y_pos - 0.04;
        for ti = 1:min(length(tbl_str),20)
            text(ax_tbl, 0.01, y_pos, tbl_str{ti}, ...
                 'Color','w','FontSize',7.5,'FontName','Monospaced', ...
                 'Units','normalized','Parent',ax_tbl);
            y_pos = y_pos - 0.04;
        end

        drawnow limitrate;
    end

    %% Status line
    fprintf('\r  Frame %d | %d msgs decoded | %d aircraft tracked | %.0fs on air   ', ...
            frame_count, msg_count, length(fieldnames(aircraft)), toc(t_start));
end

catch ME
    if ~strcmp(ME.identifier,'MATLAB:interruptedError')
        fprintf('\nError: %s\n', ME.message);
    end
end

%% Shutdown
release(rx);
fprintf('\n\nTracker stopped.\n');
fprintf('Total frames   : %d\n', frame_count);
fprintf('Total messages : %d\n', msg_count);
fprintf('Aircraft seen  : %d\n', length(fieldnames(aircraft)));

%% Helper
function d = bits2dec(bits)
    d = sum(bits .* 2.^(length(bits)-1:-1:0));
end
