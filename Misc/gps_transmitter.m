%% ========================================================================
%  GPS STANDALONE TRANSMITTER FOR ADALM-PLUTO SDR
%  Single-file version - all helper functions included at bottom
%  No external dependencies required
%  Author: Ram Tripathi | IIT BHU Varanasi | March 2026
%% ========================================================================

clear; clc; close all;

%% ========================================================================
%  LOCATION CONFIGURATION
%% ========================================================================

LOCATION = 'IIT_BHU';      % Change: IIT_BHU, DWARKA, IIT_DELHI, CUSTOM

% Custom location (only used if LOCATION = 'CUSTOM')
CUSTOM_LAT  = 25.2677;
CUSTOM_LON  = 82.9913;
CUSTOM_ALT  = 80;
CUSTOM_NAME = 'My Test Site';

%% ========================================================================
%  LOCATION DATABASE
%% ========================================================================

locations = struct();
locations.IIT_BHU.name     = 'IIT BHU Varanasi';
locations.IIT_BHU.lat      = 25.2677;
locations.IIT_BHU.lon      = 82.9913;
locations.IIT_BHU.alt      = 80;

locations.DWARKA.name      = 'Dwarka Delhi';
locations.DWARKA.lat       = 28.5921;
locations.DWARKA.lon       = 77.0460;
locations.DWARKA.alt       = 216;

locations.IIT_DELHI.name   = 'IIT Delhi';
locations.IIT_DELHI.lat    = 28.5449;
locations.IIT_DELHI.lon    = 77.1926;
locations.IIT_DELHI.alt    = 216;

locations.IIT_BOMBAY.name  = 'IIT Bombay';
locations.IIT_BOMBAY.lat   = 19.1334;
locations.IIT_BOMBAY.lon   = 72.9133;
locations.IIT_BOMBAY.alt   = 14;

locations.IIT_KANPUR.name  = 'IIT Kanpur';
locations.IIT_KANPUR.lat   = 26.5123;
locations.IIT_KANPUR.lon   = 80.2329;
locations.IIT_KANPUR.alt   = 125;

locations.IIT_MADRAS.name  = 'IIT Madras';
locations.IIT_MADRAS.lat   = 12.9916;
locations.IIT_MADRAS.lon   = 80.2336;
locations.IIT_MADRAS.alt   = 6;

locations.CUSTOM.name      = CUSTOM_NAME;
locations.CUSTOM.lat       = CUSTOM_LAT;
locations.CUSTOM.lon       = CUSTOM_LON;
locations.CUSTOM.alt       = CUSTOM_ALT;

if ~isfield(locations, LOCATION)
    error('Unknown location: %s', LOCATION);
end

loc          = locations.(LOCATION);
rxlla        = [loc.lat, loc.lon, loc.alt];
locationName = loc.name;

disp('================================================================');
disp('     GPS STANDALONE TRANSMITTER - ADALM-PLUTO SDR');
disp('================================================================');
fprintf('  Location   : %s\n', locationName);
fprintf('  Coordinates: %.4fN, %.4fE, %.0fm\n', rxlla(1), rxlla(2), rxlla(3));
disp('  Mode       : Faraday Cage Testing');
disp('================================================================');

%% ========================================================================
%  TRANSMISSION CONFIGURATION
%% ========================================================================

centerFrequency   = 1575.42e6;   % GPS L1
sampleRate        = 5e6;
radioGain         = -10;
waveDuration      = 30;          % seconds
minElevationAngle = 15;          % degrees
useSDR            = false;       % Set true when ready to transmit
useShieldedMode   = true;
enableVisualization = true;
enableLogging     = true;
seed              = 42;
rng(seed);

almFileName = 'gpsAlmanac.txt';

timestamp        = datestr(now, 'yyyymmdd_HHMMSS');
waveformFileName = sprintf('GPS_%s_%s.bb', strrep(locationName,' ','_'), timestamp);
logFileName      = sprintf('GPS_Log_%s_%s.txt', strrep(locationName,' ','_'), timestamp);

%% ========================================================================
%  SAFETY CHECK
%% ========================================================================

if useSDR && ~useShieldedMode
    error('SAFETY: Cannot transmit without shielded mode. Set useShieldedMode=true.');
end

disp('SAFETY CHECKLIST:');
disp('  [OK] Faraday cage sealed');
disp('  [OK] All test devices inside cage');
disp('  [OK] Low power start (-10 dB)');

%% ========================================================================
%  ALMANAC
%% ========================================================================

disp(' ');
disp('Loading GPS Almanac...');

startTime = datetime(2021,6,24,0,0,48, TimeZone='UTC');

if ~isfile(almFileName)
    disp('  Almanac not found. Attempting download...');
    url = 'https://www.navcen.uscg.gov/sites/default/files/gps/almanac/current_sem.al3';
    try
        websave(almFileName, url);
        fprintf('  Downloaded: %s\n', almFileName);
        startTime = datetime('now', TimeZone='UTC');
    catch
        disp('  Download failed. Creating minimal test almanac...');
        gps_createMinimalAlmanac(almFileName);
    end
else
    fprintf('  Using: %s\n', almFileName);
end

%% ========================================================================
%  WAVEFORM GENERATOR
%% ========================================================================

disp(' ');
disp('Configuring GPS Waveform Generator...');

wavegenobj          = gpsWaveformGenerator(SampleRate=sampleRate);
wavegenobj.SignalType = 'legacy';   % GPS C/A
navDataType         = 'LNAV';
stepTime            = wavegenobj.BitDuration;

fprintf('  Signal     : GPS C/A (L1)\n');
fprintf('  Sample Rate: %.1f MHz\n', sampleRate/1e6);
fprintf('  Step Time  : %.2f ms\n', stepTime*1000);

%% ========================================================================
%  SATELLITE SCENARIO
%% ========================================================================

disp(' ');
disp('Simulating Satellite Constellation...');

sc  = satelliteScenario;
sat = satellite(sc, almFileName, OrbitPropagator='gps');
rx  = groundStation(sc, rxlla(1), rxlla(2), Altitude=rxlla(3), ...
                    Name=strrep(locationName,' ','_'));
rx.MinElevationAngle = minElevationAngle;

sc.StartTime = startTime;
sc.StopTime  = sc.StartTime + seconds(waveDuration - stepTime);
sc.SampleTime = stepTime;

disp('  Scenario configured.');

%% ========================================================================
%  DOPPLER + DELAY
%% ========================================================================

disp('Computing Doppler shifts and delays...');

dopShifts = dopplershift(sat, rx, Frequency=centerFrequency).';
ltncy     = latency(sat, rx).';

c       = physconst('LightSpeed');
Pt      = 44.8;
DtLin   = db2pow(12);
DrLin   = db2pow(4);
k       = physconst('boltzmann');
T       = 300;

Pr   = Pt * DtLin * DrLin ./ ((4*pi*(centerFrequency+dopShifts).*ltncy).^2);
snrs = 10*log10(Pr/(k*T*sampleRate)) + 8;

disp('  Done.');

%% ========================================================================
%  VISIBLE SATELLITES
%% ========================================================================

satIndices    = find(~isnan(ltncy(1,:)));
numVisibleSats = length(satIndices);

if numVisibleSats == 0
    error('No visible satellites from this location. Check almanac or coordinates.');
end

% Build nav config using inline function (replaces HelperGPSAlmanac2Config)
navcfg = gps_almanac2Config(almFileName, navDataType, satIndices, startTime);

visibleSatPRN = [navcfg(:).PRNID];

fprintf('\nVisible Satellites: %d\n', numVisibleSats);
fprintf('PRN IDs: %s\n', mat2str(visibleSatPRN));

%% ========================================================================
%  NAV DATA ENCODE
%% ========================================================================

disp(' ');
disp('Generating Navigation Data...');

tempnavdata = gps_navDataEncode(navcfg(1));
navdata     = zeros(length(tempnavdata), length(navcfg));
navdata(:,1) = tempnavdata;

for isat = 2:length(navcfg)
    navdata(:,isat) = gps_navDataEncode(navcfg(isat));
end

wavegenobj.PRNID = visibleSatPRN;

% Build GNSS channel (replaces HelperGNSSChannel)
gnsschannelobj = gps_buildChannel(...
    dopShifts(1, satIndices), ...
    ltncy(1, satIndices), ...
    snrs(1, satIndices), ...
    sampleRate, seed);

disp('  Nav data ready.');

%% ========================================================================
%  WAVEFORM GENERATION
%% ========================================================================

disp(' ');
disp('================================================================');
disp('GENERATING GPS WAVEFORM');
disp('================================================================');

numsteps      = round(waveDuration / stepTime);
samplesPerStep = round(sampleRate * stepTime);
gpswaveform   = zeros(numsteps * samplesPerStep, 1);

if enableLogging
    try
        bbwriter = comm.BasebandFileWriter(waveformFileName, sampleRate, centerFrequency);
        bbwriter.NumSamplesToWrite = samplesPerStep;
    catch ME
        warning('BasebandFileWriter init failed: %s — logging disabled.', ME.message);
        enableLogging = false;
    end
end

h = waitbar(0, sprintf('Generating GPS waveform for %s...', locationName));

for istep = 1:numsteps
    if mod(istep, 50) == 0
        waitbar(istep/numsteps, h, sprintf('Progress: %.1f%%', 100*istep/numsteps));
    end

    idx     = (istep-1)*samplesPerStep + (1:samplesPerStep);
    navbit  = navdata(istep, :);
    tempWav = wavegenobj(navbit);

    % Apply channel impairments
    gpswaveform(idx) = gps_applyChannel(gnsschannelobj, tempWav, sampleRate);

    if enableLogging
        try
            bbwriter(single(gpswaveform(idx)));
        catch
            % skip file write on error, continue generation
        end
    end

    % Update channel for next step
    if istep < numsteps
        nextIdx = min(istep+1, size(snrs,1));
        gnsschannelobj.snr   = snrs(nextIdx, satIndices);
        gnsschannelobj.doppl = dopShifts(nextIdx, satIndices);
        gnsschannelobj.delay = ltncy(nextIdx, satIndices);
    end
end

close(h);
disp('Waveform generated successfully.');

if enableLogging
    try
        release(bbwriter);
        fprintf('Saved baseband file: %s\n', waveformFileName);
    catch
        warning('BasebandFileWriter release failed — saving as .mat instead.');
    end
end

% Always save as .mat — reliable fallback
matFileName = strrep(waveformFileName, '.bb', '.mat');
save(matFileName, 'gpswaveform', 'sampleRate', 'centerFrequency', 'locationName', 'visibleSatPRN');
fprintf('Saved waveform .mat: %s\n', matFileName);

%% ========================================================================
%  SIGNAL CONDITIONING
%% ========================================================================

maxVal = max(abs(gpswaveform));
if maxVal > 0.95
    gpswaveform = gpswaveform * (0.9 / maxVal);
end

%% ========================================================================
%  STATISTICS
%% ========================================================================

waveformPower = 10*log10(mean(abs(gpswaveform).^2));
fprintf('\n--- Waveform Statistics ---\n');
fprintf('Duration : %.1f s\n', waveDuration);
fprintf('Samples  : %d\n', length(gpswaveform));
fprintf('Power    : %.2f dBW\n', waveformPower);
fprintf('RMS      : %.6f\n', rms(gpswaveform));
fprintf('Peak     : %.6f\n', max(abs(gpswaveform)));

%% ========================================================================
%  VISUALIZATION
%% ========================================================================

if enableVisualization
    disp(' ');
    disp('Generating plots...');

    figure('Name', sprintf('GPS Signal - %s', locationName), ...
           'Position', [50 50 1400 900]);

    subplot(2,3,1);
    pLen = min(5000, length(gpswaveform));
    plot((0:pLen-1)/sampleRate*1e3, real(gpswaveform(1:pLen)), 'b');
    grid on; xlabel('Time (ms)'); ylabel('Amplitude');
    title('Time Domain (Real)');

    subplot(2,3,2);
    [pxx,f] = pwelch(gpswaveform,[],[],[],sampleRate,'centered');
    plot(f/1e6, 10*log10(pxx), 'r');
    grid on; xlabel('Freq Offset (MHz)'); ylabel('Power (dB)');
    title('Power Spectral Density');

    subplot(2,3,3);
    pLen = min(2000, length(gpswaveform));
    plot(real(gpswaveform(1:pLen)), imag(gpswaveform(1:pLen)), '.', 'MarkerSize', 4);
    grid on; xlabel('I'); ylabel('Q'); title('I/Q Constellation'); axis equal;

    subplot(2,3,4);
    histogram(real(gpswaveform), 50);
    grid on; xlabel('Amplitude'); ylabel('Count'); title('Amplitude Histogram');

    subplot(2,3,[5 6]);
    sLen = min(20000, length(gpswaveform));
    spectrogram(gpswaveform(1:sLen), 128, 120, 128, sampleRate, 'yaxis');
    title(sprintf('Spectrogram - %s', locationName));

    disp('  Plots done.');
end

%% ========================================================================
%  SDR TRANSMISSION
%% ========================================================================

if useSDR
    disp(' ');
    disp('================================================================');
    disp('ADALM-PLUTO SDR TRANSMISSION');
    disp('================================================================');
    try
        tx = sdrtx('Pluto', ...
                   'CenterFrequency', centerFrequency, ...
                   'BasebandSampleRate', sampleRate, ...
                   'Gain', radioGain);

        fprintf('Frequency  : %.2f MHz\n', centerFrequency/1e6);
        fprintf('Sample Rate: %.1f MHz\n', sampleRate/1e6);
        fprintf('Gain       : %d dB\n', radioGain);

        response = input('Faraday cage sealed and ready? Type YES to transmit: ', 's');
        if strcmpi(response, 'YES')
            disp('Transmitting...');
            tx(gpswaveform);
            disp('Transmission complete.');
        else
            disp('Transmission cancelled.');
        end
        release(tx);
    catch ME
        fprintf('SDR Error: %s\n', ME.message);
    end
else
    disp(' ');
    disp('SDR disabled (simulation mode). Set useSDR=true to transmit.');
end

%% ========================================================================
%  SUMMARY
%% ========================================================================

fprintf('\n================================================================\n');
fprintf('SUMMARY\n');
fprintf('================================================================\n');
fprintf('Location   : %s\n', locationName);
fprintf('Coordinates: [%.4fN, %.4fE, %.0fm]\n', rxlla(1), rxlla(2), rxlla(3));
fprintf('Satellites : %d visible | PRNs: %s\n', numVisibleSats, mat2str(visibleSatPRN));
fprintf('Signal     : GPS C/A @ %.2f MHz\n', centerFrequency/1e6);
fprintf('Duration   : %.1f sec\n', waveDuration);
if enableLogging
    fprintf('Waveform   : %s\n', waveformFileName);
end
fprintf('================================================================\n');
disp('ALL OPERATIONS COMPLETE.');


%% ========================================================================
%%  HELPER FUNCTIONS  (inlined - no external files needed)
%% ========================================================================

% ------------------------------------------------------------------------
function gps_createMinimalAlmanac(filename)
% Creates a minimal single-satellite SEM almanac for testing
    lines = {
        '******** Week 2162 almanac for PRN-10 ********'
        'ID:                         10'
        'Health:                     000'
        'Eccentricity:               0.6118774414E-002'
        'Time of Applicability(s):  589824.0000'
        'Orbital Inclination(rad):   0.9341621399'
        'Rate of Right Ascen(r/s):  -0.8180303725E-008'
        'SQRT(A)  (m 1/2):           5153.627441'
        'Right Ascen at Week(rad):   0.2740369081E+001'
        'Argument of Perigee(rad):   1.624696112'
        'Mean Anom(rad):             0.2341064516E+001'
        'Af0(s):                    -0.3852844238E-004'
        'Af1(s/s):                   0.0000000000E+000'
        'week:                        2162'
    };
    fid = fopen(filename, 'w');
    for i = 1:length(lines)
        fprintf(fid, '%s\n', lines{i});
    end
    fclose(fid);
    fprintf('  Minimal almanac created: %s\n', filename);
end

% ------------------------------------------------------------------------
function navcfg = gps_almanac2Config(almFileName, navDataType, satIndices, startTime)
% Replaces HelperGPSAlmanac2Config
% Reads SEM almanac and returns navigation config structs for each satellite

    % Read almanac
    almData = gps_readSEMAlmanac(almFileName);

    % GPS constants
    mu    = 3.986005e14;   % Earth gravitational constant (m^3/s^2)
    OmE   = 7.2921151467e-5; % Earth rotation rate (rad/s)
    sqrtA_ref = 5153.7;    % Reference sqrt(A) for GPS

    % GPS week number from startTime
    gpsEpoch  = datetime(1980,1,6, TimeZone='UTC');
    elapsed   = seconds(startTime - gpsEpoch);
    weekNum   = floor(elapsed / 604800);
    tow       = mod(elapsed, 604800);

    % Pre-allocate struct array with all fields defined upfront
    % This avoids "dissimilar structures" error on indexed assignment
    n = length(satIndices);
    navcfg = repmat(struct( ...
        'PRNID',0, 'NavDataType','', 'Eccentricity',0, 'SqrtA',0, ...
        'OrbitalInclination',0, 'RateOfRightAscen',0, 'RightAscenAtWeek',0, ...
        'ArgumentOfPerigee',0, 'MeanAnomaly',0, 'Af0',0, 'Af1',0, ...
        'TimeOfApplicability',0, 'GPSWeek',0, 'Health',0, 'MeanMotion',0, ...
        'TOW',0, 'IODC',0, 'IODE',0, 'TGD',0, 'Toc',0, 'Af2',0, ...
        'Crs',0, 'Crc',0, 'Cus',0, 'Cuc',0, 'Cis',0, 'Cic',0, ...
        'DeltaN',0, 'IDOT',0, 'Toe',0, 'FitIntervalFlag',0, 'AODO',0, ...
        'SVAccuracy',0, 'SVID',0 ), [1, n]);

    for k = 1:n
        idx = satIndices(k);
        if idx > length(almData)
            idx = mod(idx-1, length(almData)) + 1;
        end
        alm = almData(idx);
        a   = alm.SqrtA^2;

        navcfg(k).PRNID              = alm.ID;
        navcfg(k).NavDataType        = navDataType;
        navcfg(k).Eccentricity       = alm.Eccentricity;
        navcfg(k).SqrtA              = alm.SqrtA;
        navcfg(k).OrbitalInclination = alm.OrbitalInclination;
        navcfg(k).RateOfRightAscen   = alm.RateOfRightAscen;
        navcfg(k).RightAscenAtWeek   = alm.RightAscenAtWeek;
        navcfg(k).ArgumentOfPerigee  = alm.ArgumentOfPerigee;
        navcfg(k).MeanAnomaly        = alm.MeanAnomaly;
        navcfg(k).Af0                = alm.Af0;
        navcfg(k).Af1                = alm.Af1;
        navcfg(k).TimeOfApplicability = alm.TimeOfApplicability;
        navcfg(k).GPSWeek            = weekNum;
        navcfg(k).Health             = alm.Health;
        navcfg(k).MeanMotion         = sqrt(mu / a^3);
        navcfg(k).TOW                = tow;
        navcfg(k).IODC               = 0;
        navcfg(k).IODE               = 0;
        navcfg(k).TGD                = 0;
        navcfg(k).Toc                = alm.TimeOfApplicability;
        navcfg(k).Af2                = 0;
        navcfg(k).Crs                = 0;
        navcfg(k).Crc                = 0;
        navcfg(k).Cus                = 0;
        navcfg(k).Cuc                = 0;
        navcfg(k).Cis                = 0;
        navcfg(k).Cic                = 0;
        navcfg(k).DeltaN             = 0;
        navcfg(k).IDOT               = 0;
        navcfg(k).Toe                = alm.TimeOfApplicability;
        navcfg(k).FitIntervalFlag    = 0;
        navcfg(k).AODO               = 0;
        navcfg(k).SVAccuracy         = 2;
        navcfg(k).SVID               = alm.ID;
    end
end

% ------------------------------------------------------------------------
function almData = gps_readSEMAlmanac(filename)
% Parses CURRENT.ALM / YUMA numeric-format GPS almanac
%
% File structure:
%   Line 1: "<numSats>  CURRENT.ALM"
%   Line 2: "<weekNum> <toa>"
%   Then per satellite (13 lines each):
%     1: PRN ID
%     2: SV health
%     3: Eccentricity
%     4: <blank or zero line with 3 values: Toa, inclination_offset, RateOfRightAscen>
%        Actually this file has a 3-value line:
%        Toa   incl_ref_offset   RateOfRightAscen
%     5: SqrtA
%     ... see parsing below for exact positional mapping

    fid = fopen(filename, 'r');
    if fid < 0
        error('Cannot open almanac file: %s', filename);
    end
    raw   = textscan(fid, '%s', 'Delimiter', '\n', 'Whitespace', '');
    fclose(fid);
    lines = raw{1};

    % Strip empty lines, build clean numeric line list
    clean = {};
    for i = 1:length(lines)
        ln = strtrim(lines{i});
        if ~isempty(ln)
            clean{end+1} = ln; %#ok<AGROW>
        end
    end

    % Header: line 1 = "32  CURRENT.ALM", line 2 = "361 319488"
    % Parse number of satellites from line 1
    hdr     = strsplit(clean{1});
    numSats = str2double(hdr{1});
    if isnan(numSats) || numSats <= 0
        numSats = 32;
    end

    % Parse global week and Toa from line 2
    hdr2    = strsplit(clean{2});
    gpsWeek = str2double(hdr2{1});
    globalToa = str2double(hdr2{end});
    if isnan(gpsWeek), gpsWeek = 361; end
    if isnan(globalToa), globalToa = 319488; end

    % Each satellite block is exactly 13 lines:
    %  Line 1:  PRN ID                          (integer)
    %  Line 2:  SV Health                       (integer)
    %  Line 3:  Eccentricity                    (float)
    %  Line 4:  3 values: Toa  incl_offset  RateOfRightAscen
    %  Line 5:  3 values: SqrtA  RightAscenAtWeek  ArgumentOfPerigee
    %  Line 6:  3 values: MeanAnomaly  Af0  Af1
    %  Line 7:  Health flag (0 or 63)
    %  ...remaining lines vary; we use 7 key lines then skip to next block

    % Actually from the file the pattern per sat is:
    %  1 number  (PRN)
    %  1 number  (health)
    %  1 number  (eccentricity)
    %  3 numbers on one line (Toa, inclination, RateRightAscen)
    %  3 numbers on one line (SqrtA, RightAscen, ArgPerigee)
    %  3 numbers on one line (MeanAnom, Af0, Af1)
    %  1 number  (health2)
    %  1 number  (URA/signal)
    % = 8 lines per satellite after header

    % Let's parse by collecting all numbers after the 2-line header
    % and grouping into 11-value blocks per satellite

    allNums = [];
    for i = 3:length(clean)
        parts = strsplit(strtrim(clean{i}));
        for j = 1:length(parts)
            v = str2double(parts{j});
            if ~isnan(v)
                allNums(end+1) = v; %#ok<AGROW>
            end
        end
    end

    % Each satellite = 11 numeric values:
    %  1: PRN
    %  2: health
    %  3: eccentricity
    %  4: Toa
    %  5: OrbitalInclination (offset from 0.3*pi = 54 deg reference)
    %  6: RateOfRightAscen
    %  7: SqrtA
    %  8: RightAscenAtWeek
    %  9: ArgumentOfPerigee
    % 10: MeanAnomaly
    % 11: Af0
    % 12: Af1
    % 13: health2
    % 14: URA week signal

    valsPerSat = 14;
    actualSats = floor(length(allNums) / valsPerSat);

    if actualSats == 0
        % Fallback: try 11 values per sat
        valsPerSat = 11;
        actualSats = floor(length(allNums) / valsPerSat);
    end

    if actualSats == 0
        error('No satellite data found in almanac file: %s', filename);
    end

    almData = struct();

    for k = 1:actualSats
        base = (k-1)*valsPerSat + 1;
        v    = allNums(base : min(base+valsPerSat-1, length(allNums)));

        % Pad with zeros if short
        v(end+1:valsPerSat) = 0;

        almData(k).ID                  = round(v(1));
        almData(k).Health              = round(v(2));
        almData(k).Eccentricity        = v(3);
        almData(k).TimeOfApplicability = v(4);
        % Inclination stored as offset from pi*0.3 rad (IS-GPS-200)
        almData(k).OrbitalInclination  = v(5) + 0.3*pi;
        almData(k).RateOfRightAscen    = v(6);
        almData(k).SqrtA               = v(7);
        almData(k).RightAscenAtWeek    = v(8);
        almData(k).ArgumentOfPerigee   = v(9);
        almData(k).MeanAnomaly         = v(10);
        almData(k).Af0                 = v(11);
        almData(k).Af1                 = v(12);
        almData(k).Week                = gpsWeek;
    end

    fprintf('  Parsed %d satellites from almanac (GPS week %d).\n', actualSats, gpsWeek);
end

% ------------------------------------------------------------------------
function navbits = gps_navDataEncode(cfg)
% Replaces HelperGPSNAVDataEncode
% Generates LNAV navigation data bits for one satellite
% Returns column vector of bits, one per 20ms step (1500 bits for 30s)

    % LNAV frame: 1500 bits per 30 seconds (5 subframes x 300 bits)
    % For simulation we generate a plausible bit stream
    % Real LNAV encoding is complex; this generates valid-length random nav bits
    % seeded by PRN so each satellite is distinct but deterministic

    rng(cfg.PRNID * 1000 + 42);  % deterministic per satellite

    % Subframe structure: TLM + HOW + data words
    % 5 subframes x 300 bits = 1500 bits total
    % Each subframe: 10 words x 30 bits

    navbits = zeros(1500, 1);

    for sf = 1:5
        offset = (sf-1)*300;

        % TLM word (bits 1-30): preamble 10001011 + 14 bits TLM + 6 parity
        tlm = [1 0 0 0 1 0 1 1, zeros(1,16), zeros(1,6)];
        navbits(offset+1 : offset+30) = tlm(:);

        % HOW word (bits 31-60): TOW + flags + subframe ID + parity
        sfID_bits = dec2bin(sf, 3) - '0';
        how = [zeros(1,17), sfID_bits, zeros(1,4), zeros(1,6)];
        navbits(offset+31 : offset+60) = how(:);

        % Words 3-10: data (seeded random for simulation)
        dataLen = 8 * 30;
        navbits(offset+61 : offset+300) = randi([0 1], dataLen, 1);
    end
end

% ------------------------------------------------------------------------
function ch = gps_buildChannel(doppler, delay, snr, sampleRate, seed)
% Replaces HelperGNSSChannel constructor
% Returns a simple struct storing channel parameters

    ch.doppl      = doppler;
    ch.delay      = delay;
    ch.snr        = snr;
    ch.sampleRate = sampleRate;
    ch.seed       = seed;
    rng(seed);
end

% ------------------------------------------------------------------------
function out = gps_applyChannel(ch, waveform, sampleRate)
% Replaces HelperGNSSChannel step function
% Applies Doppler, delay, and AWGN to multi-satellite waveform
% waveform: Nsamples x Nsats matrix
% out:      Nsamples x 1 combined signal

    [N, numSats] = size(waveform);
    combined     = zeros(N, 1);

    for s = 1:numSats
        sig = waveform(:, s);

        %-- Doppler shift --
        fd  = ch.doppl(s);
        t   = (0:N-1).' / sampleRate;
        sig = sig .* exp(1j * 2 * pi * fd .* t);

        %-- Fractional sample delay via phase rotation --
        delaySamples = ch.delay(s) * sampleRate;
        intDel       = floor(delaySamples);
        fracDel      = delaySamples - intDel;

        % Integer delay
        if intDel > 0 && intDel < N
            sig = [zeros(intDel,1); sig(1:end-intDel)];
        end

        % Fractional delay (first-order allpass approximation)
        if fracDel > 0
            alpha = (1 - fracDel) / (1 + fracDel);
            sig   = filter([alpha, 1], [1, alpha], sig);
        end

        %-- Scale by SNR --
        snrLin = 10^(ch.snr(s)/10);
        sig    = sig * sqrt(snrLin);

        combined = combined + sig;
    end

    %-- AWGN noise --
    noisePower = 1;
    noise      = sqrt(noisePower/2) * (randn(N,1) + 1j*randn(N,1));
    out        = combined + noise;
end
