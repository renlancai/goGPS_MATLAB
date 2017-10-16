classdef Core_Sky < handle
    
    
    %--- * --. --- --. .--. ... * ---------------------------------------------
    %               ___ ___ ___
    %     __ _ ___ / __| _ | __
    %    / _` / _ \ (_ |  _|__ \
    %    \__, \___/\___|_| |___/
    %    |___/                    v 0.5.1 beta 3
    %
    %--------------------------------------------------------------------------
    %  Copyright (C) 2009-2017 Mirko Reguzzoni, Eugenio Realini
    %  Written by: Giulio Tagliaferro
    %  Contributors:     ...
    %  A list of all the historical goGPS contributors is in CREDITS.nfo
    %--------------------------------------------------------------------------
    %
    %   This program is free software: you can redistribute it and/or modify
    %   it under the terms of the GNU General Public License as published by
    %   the Free Software Foundation, either version 3 of the License, or
    %   (at your option) any later version.
    %
    %   This program is distributed in the hope that it will be useful,
    %   but WITHOUT ANY WARRANTY; without even the implied warranty of
    %   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    %   GNU General Public License for more details.
    %
    %   You should have received a copy of the GNU General Public License
    %   along with this program.  If not, see <http://www.gnu.org/licenses/>.
    %
    %--------------------------------------------------------------------------
    % 01100111 01101111 01000111 01010000 01010011
    %--------------------------------------------------------------------------
    
    properties
        time_ref  % Gps Times of tabulated aphemerids
        time_zero_idx_coord % index of zero time in coord
        time_zero_idx_clk % index of zero time in clk
        coord  % cvoordinates of tabulated aphemerids [times x num_sat x 3]
        clock  % cloks of tabulated aphemerids [times x num_sat]
        prn
        sys
        time_hr
        clock_hr
        coord_rate = 900;
        clock_rate = 900;
        iono
        t_sun  % time of sun ephemerids
        X_sun  % coord of sun ephemerids
        t_sun_rate
        X_moon
        ERP  % EARH rotation parameters
        DCB  % differential code biases
        antenna_PCO   %% satellites antenna phase center offset
        antenna_PCV  %% satellites antenna phase center variations
        satType
        avail
        coord_pol_coeff %% coefficient of the polynomial interpolation for coordinates [11,3,num_sat,num_coeff_sets]
        start_time_idx  %%% index  defininig start of the day (time == 1)
        cc
        
    end
    properties (Access = private)
        
        logger
        state
    end
    methods (Access = 'private')
        
        % Creator
        function this = Core_Sky()
            % Core object creator
            this.state = Go_State.getCurrentSettings();
            this.logger = Logger.getInstance();
            this.cc = Go_State.getCurrentSettings().getConstellationCollector();
            this.antenna_PCO =zeros(1,this.cc.getNumSat(),3);
            
        end
    end
    
    methods (Static)
        % Concrete implementation.  See Singleton superclass.
        function this = getInstance()
            % Get the persistent instance of the class
            persistent unique_instance_core_sky__
            
            if isempty(unique_instance_core_sky__)
                this = Core_Sky();
                unique_instance_core_sky__ = this;
            else
                this = unique_instance_core_sky__;
            end
        end
    end
    % =========================================================================
    %  METHODS
    % =========================================================================
    
    methods % Public Access
        
        function importEph(this, eph, t_st, t_end, sat, step)
            % SYNTAX:
            %   eph_tab.importEph(eph, t_st, t_end, sat, step)
            %
            % INPUT:
            %   eph         = ephemerids matrix
            %   t_st        = start_time
            %   t_end       = start_time
            %   sat         = available satellite indexes
            %
            % OUTPUT:
            %   XS      = satellite position at time in ECEF(time_rx) (X,Y,Z)
            %   VS      = satellite velocity at time in ECEF(time_tx) (X,Y,Z)
            %   dtS     = satellite clock error (vector)
            %
            % DESCRIPTION:
            
            if nargin < 6
                step = 900;
            end
            this.coord_rate = step;
            this.clock_rate = step;
            if nargin < 4 || t_end.isempty()
                t_end = t_st;
            end
            times = t_st.getGpsTime -5*step : step : t_end.getGpsTime+5*step; %%% compute 5 step before and after the day to use for polynomila interpolation
            this.time=times;
            
            sat = intersect(sat,unique(eph(30,:))); %% keep only satellite also present in eph
            i = 0;
            
            this.coord = zeros(length(times), this.cc.getNumSat,3 );
            this.clock = zeros (this.cc.getNumSat, length(times));
            t_dist_exced=false;
            for t = times
                i=i+1;
                [this.coord(i,:,:), ~, this.clock(:,i), t_d_e]=this.satellitePositions(t, sat, eph); %%%% consider loss of precision problem
                t_dist_exced = t_dist_exced || t_d_e;
            end
            if t_dist_exced
                this.logger.addError(sprintf('One of the time bonds (%s , %s)\ntoo far from valid ephemerids ',t_st.toString(0),t_end.toString(0)))
            end
        end
        function importBrdc(this,f_name, t_st, t_end, sat, step)
            if nargin < 6
                step = 900;
            end
            if nargin < 5
                sat= this.cc.index;
            end
            if nargin < 4 || t_end.isempty()
                t_end = t_st;
            end
            [eph, this.iono, flag_return] = load_RINEX_nav(f_name,this.cc,0,0);
            if isempty(eph)
                
            end
            this.importEph(eph,t_st,t_end,sat,step);
            
        end
        function importSp3(this,filename_SP3, filename_CLK,t_st, t_end,step,wait_dlg)
            % SYNTAX:
            %   this.importSp3(filename_SP3, filename_CLK, t_st, t_end,step)
            %
            % INPUT:
            %   filename_SP3 = SP3 file
            %   t_st = start time
            %   t_end = end time
            %
            % OUTPUT:
            %
            % DESCRIPTION:
            %   SP3 (precise ephemeris) file parser.
            %   NOTE: at the moment the parser reads only time, coordinates and clock;
            %         it does not take into account all the other flags and parameters
            %         available according to the SP3c format specified in the document
            %         http://www.ngs.noaa.gov/orbits/sp3c.txt
            if nargin < 6
                step = 900;
            end
            if nargin < 5
                sat= this.cc.index;
            end
            if nargin < 4 || t_end.isempty()
                t_end = t_st;
            end
            logger = Logger.getInstance();
            logger.addMarkedMessage('Reading SP3s (precise ephemeris) and clocks');
            % degree of interpolation polynomial (Lagrange)
            n = 10;
            
            % number of seconds in a quarter of an hour
            quarter_sec = 900;
            
            if (nargin > 6)
                waitbar(0.5,wait_dlg,'Reading SP3 (precise ephemeris) file...')
            end
            
            % extract containing folder
            % [data_dir, file_name, file_ext] = fileparts(filename_SP3{1});
            % filename_SP3 = File_Name_Processor.checkPath(strcat(data_dir, filesep, file_name(1:3)));
            
            % define time window
            [week_start, time_start] = time2weektow(t_st.getGpsTime);
            [week_end, time_end] = time2weektow(t_end.getGpsTime);
            
            % day-of-week
            [~, ~, dow_start] = gps2date(week_start, time_start);
            [~, ~, dow_end] = gps2date(week_end, time_end);
            
            % add a buffer before and after
            % if the first obs is close to the beginning of the week
            if (t_st.getGpsTime - weektow2time(week_start, dow_start * 86400, 'G') <= n / 2 * quarter_sec)
                if (dow_start == 0)
                    week_start = week_start - 1;
                    dow_start = 6;
                else
                    dow_start = dow_start - 1;
                end
            end
            
            % if the last obs is close to the end of the week
            if (t_end.getGpsTime - weektow2time(week_end, dow_end * 86400, 'G') >= 86400 - n / 2 * quarter_sec)
                if (dow_end == 6)
                    week_end = week_end + 1;
                    dow_end = 0;
                else
                    dow_end = dow_end + 1;
                end
            else
            end
            
            % find the SP3 files dates needed for the processing
            % an SP3 file contains data for the entire day, but to interpolate it at
            % the beginning and and I also need the previous and the following file
            week_dow  = [];
            week_curr = week_start;
            dow_curr  = dow_start;
            while (week_curr <= week_end)
                while ((week_curr < week_end && dow_curr <= 6) || (week_curr == week_end && dow_curr <= dow_end))
                    week_dow = [week_dow; week_curr dow_curr];
                    dow_curr = dow_curr + 1;
                end
                week_curr = week_curr + 1;
                dow_curr = 0;
            end
            
            % init SP3 variables
            nEpochs  = 96*size(week_dow,1);
            this.time = zeros(nEpochs,1);
            this.coord = zeros(nEpochs,this.cc.getNumSat(),3);
            this.clock = zeros(this.cc.getNumSat(),nEpochs);
            this.avail = zeros(this.cc.getNumSat(),1);
            this.prn   = zeros(this.cc.getNumSat(),1);
            this.sys   = zeros(this.cc.getNumSat(),1);
            this.time_hr = [];
            this.clock_hr = [];
            this.coord_rate = 900;
            this.clock_rate = 900;
            
            k = 0; % current epoch
            new_file = false;
            flag_unavail = 0;
            
            % for each part (SP3 file)
            for p = 1 : numel(filename_SP3)
                
                %SP3 file
                f_sp3 = fopen(filename_SP3{p},'r');
                
                if p > 1
                    new_file = true;
                end
                if (f_sp3 ~= -1)
                    
                    % Read the entire sp3 file in memory
                    sp3_file = textscan(f_sp3,'%s','Delimiter', '\n');
                    if (length(sp3_file) == 1)
                        sp3_file = sp3_file{1};
                    end
                    sp3_cur_line = 1;
                    fclose(f_sp3);
                    
                    % while there are lines to process
                    while (sp3_cur_line <= length(sp3_file))
                        
                        % get the next line
                        lin = sp3_file{sp3_cur_line};  sp3_cur_line = sp3_cur_line + 1;
                        
                        if (strcmp(lin(1:2),'##'))
                            rate = str2num(lin(25:38));
                            this.coord_rate = rate;
                            this.clock_rate = rate;
                        end
                        
                        if (lin(1) == '*')
                            
                            k = k + 1;
                            
                            % read the epoch header
                            % example 1: "*  1994 12 17  0  0  0.00000000"
                            data   = sscanf(lin(2:31),'%f');
                            year   = data(1);
                            month  = data(2);
                            day    = data(3);
                            hour   = data(4);
                            minute = data(5);
                            second = data(6);
                            
                            %computation of the GPS time in weeks and seconds of week
                            [w, t] = date2gps([year, month, day, hour, minute, second]);
                            %convert GPS time-of-week to continuous time
                            if new_file
                                new_k = find(this.time(1:k-1,1) >= weektow2time(w, t, 'G'), 1, 'first');
                                if ~isempty(new_k)
                                    k = new_k;
                                end
                                new_file = false;
                            end
                            this.time(k,1) = weektow2time(w, t, 'G');
                            clear w t;
                            
                        elseif (strcmp(lin(1),'P'))
                            %read position and clock
                            %example 1: "P  1  16258.524750  -3529.015750 -20611.427050    -62.540600"
                            %example 2: "PG01   8953.350886  12240.218129 -21918.986611 999999.999999"
                            %example 3: "PG02 -13550.970765 -16758.347434 -15825.576525    274.198680  7  8  8 138"
                            sys_id = lin(2);
                            if (strcmp(sys_id,' ') || strcmp(sys_id,'G') || strcmp(sys_id,'R') || ...
                                    strcmp(sys_id,'E') || strcmp(sys_id,'C') || strcmp(sys_id,'J'))
                                
                                index = -1;
                                switch (sys_id)
                                    case {'G', ' '}
                                        if (this.cc.active_list(1))
                                            index = this.cc.getGPS.go_ids;
                                        end
                                    case 'R'
                                        if (this.cc.active_list(2))
                                            index = this.cc.getGLONASS.go_ids;
                                        end
                                    case 'E'
                                        if (this.cc.active_list(3))
                                            index = this.cc.getGalileo.go_ids;
                                        end
                                    case 'C'
                                        if (this.cc.active_list(4))
                                            index = this.cc.getBeiDou.go_ids;
                                        end
                                    case 'J'
                                        if (this.cc.active_list(5))
                                            index = this.cc.getQZSS.go_ids;
                                        end
                                end
                                
                                % If the considered line is referred to an active constellation
                                if (index >= 0)
                                    PRN = sscanf(lin(3:4),'%f');
                                    X   = sscanf(lin(5:18),'%f');
                                    Y   = sscanf(lin(19:32),'%f');
                                    Z   = sscanf(lin(33:46),'%f');
                                    clk = sscanf(lin(47:60),'%f');
                                    
                                    index = index + PRN - 1;
                                    
                                    this.coord(k, index, 1) = X*1e3;
                                    this.coord(k, index, 2) = Y*1e3;
                                    this.coord(k, index, 3) = Z*1e3;
                                    
                                    this.clock(index,k) = clk/1e6; % NOTE: clk >= 999999 stands for bad or absent clock values
                                    
                                    this.prn(index) = PRN;
                                    this.sys(index) = sys_id;
                                    
                                    if (this.clock(index,k) < 0.9)
                                        this.avail(index) = index;
                                    end
                                end
                            end
                        end
                    end
                    clear sp3_file;
                end
            end
            
            if this.time(1) > t_st.getGpsTime()
                logger.addWarning(sprintf('Some SP3 files for the processing of the beginning of the interval are missing!!!\n'));
                flag_unavail = 1;
            end
            if this.time(end) < t_end.getGpsTime()
                logger.addWarning(sprintf('Some SP3 files for the processing of the end of the interval are missing!!!\n'));
                flag_unavail = 1;
            end
            
            if (~flag_unavail)
                
                w = zeros(this.cc.getNumSat(),1);
                t = zeros(this.cc.getNumSat(),1);
                clk = zeros(this.cc.getNumSat(),1);
                q = zeros(this.cc.getNumSat(),1);
                
                % for each part (SP3 file)
                for p = 1 : numel(filename_CLK)
                    
                    if strcmp(filename_CLK(p), filename_SP3(p))
                        f_clk = -1;
                    else
                        f_clk = fopen(filename_CLK{p},'r');
                    end
                    
                    if (f_clk == -1)
                        logger.addWarning(sprintf('No clk files have been found at %s', filename_CLK{p}));
                    else
                        [~, fn, fn_ext] = fileparts(filename_CLK{p});
                        logger.addMessage(sprintf('         Using as clock file: %s%s', fn, fn_ext));
                        % read the entire clk file in memory
                        clk_file = textscan(f_clk,'%s','Delimiter', '\n');
                        if (length(clk_file) == 1)
                            clk_file = clk_file{1};
                        end
                        clk_cur_line = 1;
                        fclose(f_clk);
                        
                        % while there are lines to process
                        while (clk_cur_line <= length(clk_file))
                            
                            % get the next line
                            lin = clk_file{clk_cur_line};  clk_cur_line = clk_cur_line + 1;
                            
                            if (strcmp(lin(1:3),'AS '))
                                
                                sys_id = lin(4);
                                if (strcmp(sys_id,' ') || strcmp(sys_id,'G') || strcmp(sys_id,'R') || ...
                                        strcmp(sys_id,'E') || strcmp(sys_id,'C') || strcmp(sys_id,'J'))
                                    
                                    data = sscanf(lin([5:35 41:59]),'%f'); % sscanf can read multiple data in one step
                                    
                                    % read PRN
                                    PRN = data(1);
                                    
                                    index = -1;
                                    switch (sys_id)
                                        case {'G', ' '}
                                            if (this.cc.active_list(1) && PRN <= this.cc.getGPS.N_SAT )
                                                index = this.cc.getGPS.go_ids;
                                            end
                                        case 'R'
                                            if (this.cc.active_list(2) && PRN <= this.cc.getGLONASS.N_SAT )
                                                index = this.cc.getGLONASS.go_ids;
                                            end
                                        case 'E'
                                            if (this.cc.active_list(3) && PRN <= this.cc.getGALIELO.N_SAT )
                                                index = this.cc.getGalileo.go_ids;
                                            end
                                        case 'C'
                                            if (this.cc.active_list(4) && PRN <= this.cc.getBeiDou.N_SAT )
                                                index = this.cc.getBeiDou.go_ids;
                                            end
                                        case 'J'
                                            if (this.cc.active_list(5) && PRN <= this.cc.getQZSS.N_SAT )
                                                index = this.cc.getQZSS.go_ids;
                                            end
                                    end
                                    
                                    % If the considered line is referred to an active constellation
                                    if (index >= 0)
                                        %read epoch
                                        year   = data(2);
                                        month  = data(3);
                                        day    = data(4);
                                        hour   = data(5);
                                        minute = data(6);
                                        second = data(7);
                                        index = index + PRN - 1;
                                        q(index) = q(index) + 1;
                                        
                                        % computation of the GPS time in weeks and seconds of week
                                        [w(index,q(index)), t(index,q(index))] = date2gps([year, month, day, hour, minute, second]);
                                        clk(index,q(index)) = data(8);
                                    end
                                end
                            end
                        end
                        
                        clear clk_file;
                        
                        this.clock_rate = median(serialize(diff(t(sum(t,2)~=0,:),1,2)));
                        % rmndr tells how many observations are needed to reach the end of the last day (criptic)
                        rmndr = 86400 / this.clock_rate - mod((this.time(k,1) - this.time(1,1)) / this.clock_rate, 86400 / this.clock_rate) - 1;
                        % SP3.time_hr is the reference clock time from the first value till the end of the day of the last observation
                        this.time_hr = (this.time(1,1) : this.clock_rate : (this.time(k,1) + rmndr * this.clock_rate))';
                        this.clock_hr = zeros(this.cc.getNumSat(),length(this.time_hr));
                        
                        s = 1 : this.cc.getNumSat();
                        idx = round((weektow2time(w(s,:), t(s,:), 'G')-this.time(1,1)) / this.clock_rate) + 1;
                        for s = 1 : this.cc.getNumSat()
                            this.clock_hr(s,idx(s,w(s,:) > 0)) = clk(s,w(s,:) > 0);
                        end
                    end
                end
                
                if (this.clock_rate >= 60)
                    logger.addMarkedMessage(sprintf('Satellite clock rate: %f minutes', this.clock_rate/60));
                else
                    logger.addMarkedMessage(sprintf('Satellite clock rate: %f seconds', this.clock_rate));
                end
            end
            
            %if the required SP3 files are not available, stop the execution
            if (flag_unavail)
                error('Error: required SP3 files not available.');
            end
            
            %remove empty slots
            this.time(k+1:nEpochs) = [];
            this.coord(k+1:nEpochs,:,:) = [];
            this.clock(:,k+1:nEpochs) = [];
            
            %%% compute center of mass position (X_sat - PCO)
            this.sun_moon_pos;
            [sx ,sy, sz] = this.satellite_fixed_frameV(this.time,this.coord);
            temp_antPco=repmat(this.antenna_PCO,length(this.time),1,1);
            this.coord=this.coord + cat(3,sum(temp_antPco.*sx,3) , sum(temp_antPco.*sx,3) , sum(temp_antPco.*sx,3));
            clearvars temp_antPco
            if (nargin > 6)
                waitbar(1,wait_dlg)
            end
            logger.newLine();
            
            
        end
        function importERP(this, f_name, time)
            this.ERP = load_ERP(f_name, time);
        end
        function importDCB(data_dir_dcb,codeC1_R)
            %TBD
        end
        
        
        function importIono(this,f_name)
            [~, this.iono, flag_return ] = load_RINEX_nav(f_name,this.cc,0,0);
            if (flag_return)
                return
            end
        end
        function [sx ,sy, sz] = satellite_fixed_frame(this,time,X_sat)
            
            % SYNTAX:
            %   [i, j, k] = satellite_fixed_frame(time,X_sat);
            %
            % INPUT:
            %   time     = GPS time [nx1]
            %   X_sat    = postition of satellite [nx3]
            % OUTPUT:
            %   sx = unit vector that completes the right-handed system
            %   sy = resulting unit vector of the cross product of k vector with the unit vector from the satellite to Sun
            %   sz = unit vector pointing from the Satellite Mass Centre (MC) to the Earth's centre
            %
            % DESCRIPTION:
            %   Computation of the unit vectors defining the satellite-fixed frame.
            
            
            t_sun = this.t_sun;
            X_sun = this.X_sun;
            n_sat=size(X_sat,2);
            
            %[~, q] = min(abs(t_sun - time));
            % speed improvement of the above line
            % supposing t_sun regularly sampled
            q = round((time - t_sun(1)) / this.coord_rate) + 1;
            un_q=unique(q);
            sx = zeros(size(X_sat)); sy = sx; sz = sx;
            for idx = un_q'
                q_idx=q==idx;
                x_sun = X_sun(:,idx)';
                x_sat = X_sat(q_idx,:,:);
                e = permute(repmat(x_sun,sum(q_idx),1,n_sat),[1 3 2]) - x_sat() ;
                e = e./repmat(normAlngDir(e,3),1,1,3);
                k = -x_sat./repmat(normAlngDir(x_sat,3),1,1,3);
                j=cross(k,e);
                %                 j = [k(2).*e(3)-k(3).*e(2);
                %                     k(3).*e(1)-k(1).*e(3);
                %                     k(1).*e(2)-k(2).*e(1)];
                i=cross(j,k);
                %                 i = [j(2).*k(3)-j(3).*k(2);
                %                     j(3).*k(1)-j(1).*k(3);
                %                     j(1).*k(2)-j(2).*k(1)];
                sx(q_idx,:,:) = k;
                sy(q_idx,:,:) = j ./ repmat(normAlngDir(j,3),1,1,3);
                sz(q_idx,:,:) = i ./ repmat(normAlngDir(i,3),1,1,3);
            end
            function nrm=normAlngDir(A,d)
                nrm=sqrt(sum(A.^2,d));
            end
        end
        
        function [dt_S_SP3] = interpolate_SP3_clock(this,time, sat)
            
            % SYNTAX:
            %   [dt_S_SP3] = interpolate_SP3_clock(time, sat);
            %
            % INPUT:
            %   time  = interpolation timespan (GPS time, continuous since 6-1-1980)
            %   SP3   = structure containing precise ephemeris data
            %   sat   = satellite PRN
            %
            % OUTPUT:
            %   dt_S_SP3  = interpolated clock correction
            %
            % DESCRIPTION:
            %   SP3 (precise ephemeris) clock correction linear interpolation.
            if nargin < 3
                sat= this.cc.index;
            end
            if (isempty(this.clock_hr))
                SP3_time = this.time;
                SP3_clock = this.clock;
            else
                SP3_time = this.time_hr;
                SP3_clock = this.clock_hr;
            end
            
            interval = this.clock_rate;
            
            %find the SP3 epoch closest to the interpolation time
            %[~, p] = min(abs(SP3_time - time));
            % speed improvement of the above line
            % supposing SP3_time regularly sampled
            p = round((time - SP3_time(1)) / interval) + 1;
            
            b = SP3_time(p) - time;
            
            %extract the SP3 clocks
            if (b>0)
                SP3_c = [SP3_clock(sat,p-1) SP3_clock(sat,p)];
                u = 1 - b/interval;
            else
                SP3_c = [SP3_clock(sat,p) SP3_clock(sat,p+1)];
                u = -b/interval;
            end
            
            dt_S_SP3  = NaN*ones(size(SP3_c,1),length(time));
            idx=(sum(SP3_c~=0,2) == 2 .* ~any(SP3_c >= 0.999,2))>0;
            dt_S_SP3(idx)=(1-u)*SP3_c(idx,1) + u*SP3_c(idx,2);
            
            %             dt_S_SP3=NaN;
            %             if (sum(SP3_c~=0) == 2 && ~any(SP3_c >= 0.999))
            %
            %                 %linear interpolation (clock)
            %                 dt_S_SP3 = (1-u)*SP3_c(1) + u*SP3_c(2);
            %
            %                 %plot([0 1],SP3_c,'o',u,dt_S_SP3,'.')
            %                 %pause
            %             end
        end
        function computePolyCoeff(this)
            % SYNTAX:
            %   this.computePolyCoeff();
            %
            % INPUT:
            %
            % OUTPUT:
            %
            % DESCRIPTION: Precompute the coefficient of the 10th poynomial for all the possible support sets
            n_pol=10;
            n_coeff=n_pol+1;
            A=zeros(n_coeff,n_coeff);
            A(:,1)=ones(n_coeff,1);
            x=[-5:5]*this.coord_rate;
            for i=1:10
                A(:,i+1)=(x.^i)';
            end
            n_coeff_set= length(this.time)-10;%86400/this.coord_rate+1;
            %this.coord_pol_coeff=zeros(this.cc.getNumSat,n_coeff_set,n_coeff,3)
            this.coord_pol_coeff=zeros(n_coeff,3,this.cc.getNumSat,n_coeff_set);
            for s=1:this.cc.getNumSat
                for i=1:n_coeff_set
                    for j=1:3
                        this.coord_pol_coeff(:,j,s,i)=A\squeeze(this.coord(i:i+10,s,j));
                    end
                end
            end
        end
        function [X_sat, V_sat]=polyInterpolate(this,t,sat)
            % SYNTAX:
            %   [X_sat]=Eph_Tab.polInterpolate(t,sat)
            %
            % INPUT:
            %    t = vector of times where to interpolate
            %    sat = satellite to be interpolated (optional) (TBD
            %    multiple satellite seletcion)
            % OUTPUT:
            %
            % DESCRIPTION: Precompute the coefficient of the 10th poynomial for all the possible support sets
            n_sat=this.cc.getNumSat;
            if nargin <3
                sat_idx=ones(n_sat,1)>0;
            else
                sat_idx=sat;
            end
            n_sat=length(sat_idx);
            t_fd=t; % time from start of the day
            nt=length(t_fd);
            c_idx=round(t_fd/this.coord_rate)+this.start_time_idx;%coefficient set  index
            %l_idx=idx-5;
            %u_id=idx+10;
            
            X_sat=zeros(nt,n_sat,3);
            V_sat=zeros(nt,n_sat,3);
            un_idx=unique(c_idx);
            for idx=un_idx
                t_idx=c_idx==idx;
                times=t(t_idx);
                t_fct=((times-this.time(5+idx)))';%time from coefficient time
                %%%% compute position
                eval_vec = [ones(size(t_fct)) ...
                    t_fct ...
                    t_fct.^2 ...
                    t_fct.^3  ...
                    t_fct.^4  ...
                    t_fct.^5 ...
                    t_fct.^6  ...
                    t_fct.^7  ...
                    t_fct.^8 ...
                    t_fct.^9  ...
                    t_fct.^10];
                X_sat(t_idx,:,:) = reshape(eval_vec*reshape(this.coord_pol_coeff(:,:,sat_idx,idx),11,3*n_sat),sum(t_idx),n_sat,3);
                %%% compute velocity
                eval_vec = [ ...
                    ones(size(t_fct))  ...
                    2*t_fct  ...
                    3*t_fct.^2 ...
                    4*t_fct.^3  ...
                    5*t_fct.^4  ...
                    6*t_fct.^5  ...
                    7*t_fct.^6  ...
                    8*t_fct.^7 ...
                    9*t_fct.^8  ...
                    10*t_fct.^9];
                V_sat(t_idx,:,:) = reshape(eval_vec*reshape(this.coord_pol_coeff(2:end,:,sat_idx,idx),10,3*n_sat),sum(t_idx),n_sat,3);
                
            end
        end
        function [dtS_sat]=clockInterpolate(this,t,sat)
            % SYNTAX:
            %   [dtS_sat]=Core_Sky.clockInterpolate(t,sat)
            %
            % INPUT:
            %    t = vector of times where to interpolate
            %    sat = satellite to be interpolated (optional) (TBD
            %    multiple satellite seletcion)
            % OUTPUT:
            %
            % DESCRIPTION: Precompute the coefficient of the 10th poynomial for all the possible support sets
            n_sat=this.cc.getNumSat;
            if nargin <3
                sat_idx=ones(n_sat,1)>0;
            else
                sat_idx=sat;
            end
            n_sat=length(sat_idx);
            t_fd=t; % time from start of the day
            nt=length(t_fd);
            c_idx=round(t_fd/this.clock_rate)+this.start_time_idx;%correction index
            %l_idx=idx-5;
            %u_id=idx+10;
            
            dtS_sat=zeros(nt,n_sat);
            un_idx=unique(c_idx);
            for idx = un_idx
                t_idx=c_idx==idx;
                times=t(t_idx);
                i_fct=((times-this.time(idx))/this.clock_rate)';%interval from coefficient time
                %%%% compute position
                eval_vec = [i_fct 1-i_fct];
                dtS_sat(t_idx,:) = reshape(eval_vec*reshape(this.clock(idx:idx+1,sat_idx),2,n_sat),sum(t_idx),n_sat);
            end
        end

        function sun_moon_pos(this,p_time)
            % SYNTAX:
            %   this.Eph_Tab.polInterpolate(p_time)
            %
            % INPUT:
            %    p_time = gps time [n_epoch x 1]
            % OUTPUT:
            %
            % DESCRIPTION: Compute sun and moon psitions at the time of
            % processing
            
            global iephem km ephname inutate psicor epscor ob2000
            %time = GPS_Time((p_time(1))/86400+GPS_Time.GPS_ZERO);
            
            
            sun_id = 11; moon_id = 10; earth_id = 3;
            
            readleap; iephem = 1; ephname = 'de436.bin'; km = 1; inutate = 1; ob2000 = 0.0d0;
            
            tmatrix = j2000_icrs(1);
            
            setmod(2);
            % setdt(3020092e-7);
            setdt(5.877122033683494);
            xp = 171209e-6; yp = 414328e-6;
            
            gs = Go_State.getInstance();
            go_dir = gs.getLocalStorageDir();
            
            %if the binary JPL ephemeris file is not available, generate it
            if (exist(fullfile(go_dir, 'de436.bin'),'file') ~= 2)
                fprintf('Warning: file "de436.bin" not found in at %s\n         ... generating a new "de436.bin" file\n',fullfile(go_dir, 'de436.bin'));
                fprintf('         (this procedure may take a while, but it will be done only once on each installation):\n')
                fprintf('-------------------------------------------------------------------\n\n')
                asc2eph(436, {'ascp01950.436', 'ascp02050.436'}, fullfile(go_dir, 'de436.bin'));
                fprintf('-------------------------------------------------------------------\n\n')
            end
            
            sun_ECEF = zeros(3,length(p_time));
            moon_ECEF = zeros(3,length(p_time));
            this.t_sun = zeros(1,length(p_time));
            for e = 1 : length(p_time)
                time=GPS_Time(p_time(e)/86400+GPS_Time.GPS_Zero);
                [year , month ,day,hour,min,sec]= time.getCalEpoch();
                %UTC to TDB
                jdutc = julian(month, day+hour/24+min/1440+sec/86400, year);
                jdtdb = utc2tdb(jdutc);
                this.t_sun(e) = time.getGpsTime();%(datenum( year,month, day) - GPS_Time.GPS_ZERO)*86400;
                %precise celestial pole (disabled)
                [psicor, epscor] = celpol(jdtdb, 1, 0.0d0, 0.0d0);
                
                %compute the Sun position (ICRS coordinates)
                rrd = jplephem(jdtdb, sun_id, earth_id);
                sun_ECI = rrd(1:3);
                sun_ECI = tmatrix*sun_ECI;
                
                %Sun ICRS coordinates to ITRS coordinates
                deltat = getdt;
                jdut1 = jdutc - deltat;
                tjdh = floor(jdut1); tjdl = jdut1 - tjdh;
                sun_ECEF(:,e) = celter(tjdh, tjdl, xp, yp, sun_ECI);
                
                if (nargout > 1)
                    %compute the Moon position (ICRS coordinates)
                    rrd = jplephem(jdtdb, moon_id, earth_id);
                    moon_ECI = rrd(1:3);
                    moon_ECI = tmatrix*moon_ECI;
                    
                    %Moon ICRS coordinates to ITRS coordinates
                    deltat = getdt;
                    jdut1 = jdutc - deltat;
                    tjdh = floor(jdut1); tjdl = jdut1 - tjdh;
                    moon_ECEF(:,e) = celter(tjdh, tjdl, xp, yp, moon_ECI);
                end
            end
            
            this.X_sun  = sun_ECEF*1e3;
            this.X_moon = moon_ECEF*1e3;
            
            %this.t_sun_rate =
        end
        function [eclipsed] = check_eclipse_condition(time, XS, sat,p_rate)  %%% TO BE CORRECT
            
            % SYNTAX:
            %   [eclipsed] = check_eclipse_condition(time, XS, SP3, sat, p_rate);
            %
            % INPUT:
            %   time     = GPS time
            %   XS       = satellite position (X,Y,Z)
            %   SP3      = structure containing precise ephemeris data
            %   p_rate   = processing interval [s]
            %   sat      = satellite PRN
            %
            % OUTPUT:
            %   eclipsed = boolean value to define satellite eclipse condition (0: OK, 1: eclipsed)
            %
            % DESCRIPTION:
            %   Check if the input satellite is under eclipse condition.
            
            eclipsed = 0;
            
            t_sun = this.t_sun;
            X_sun = this.X_sun;
            
            %[~, q] = min(abs(t_sun - time));
            % speed improvement of the above line
            % supposing t_sun regularly sampled
            q = round((time - t_sun(1)) /this.sun_rate) + 1;
            
            X_sun = X_sun(:,q);
            
            %satellite geocentric position
            XS_n = norm(XS);
            XS_u = XS / XS_n;
            
            %sun geocentric position
            X_sun_n = norm(X_sun);
            X_sun_u = X_sun / X_sun_n;
            
            %satellite-sun angle
            %cosPhi = dot(XS_u, X_sun_u);
            % speed improvement of the above line
            cosPhi = sum(conj(XS_u').*X_sun_u);
            
            
            %threshold to detect noon/midnight maneuvers
            if (~isempty(strfind(this.satType{sat},'BLOCK IIA')))
                t = 4.9*pi/180; % maximum yaw rate of 0.098 deg/sec (Kouba, 2009)
            elseif (~isempty(strfind(this.satType{sat},'BLOCK IIR')))
                t = 2.6*pi/180; % maximum yaw rate of 0.2 deg/sec (Kouba, 2009)
            elseif (~isempty(strfind(this.satType{sat},'BLOCK IIF')))
                t = 4.35*pi/180; % maximum yaw rate of 0.11 deg/sec (Dilssner, 2010)
            else
                t = 0; %ignore noon/midnight maneuvers for other constellations (TBD)
            end
            
            %shadow crossing affects only BLOCK IIA satellites
            shadowCrossing = cosPhi < 0 && XS_n*sqrt(1 - cosPhi^2) < goGNSS.ELL_A_GPS;
            if (shadowCrossing && ~isempty(strfind(SP3.satType{sat},'BLOCK IIA')))
                eclipsed = 1;
            end
            
            %noon/midnight maneuvers affect all satellites
            noonMidnightTurn = acos(abs(cosPhi)) < t;
            if (noonMidnightTurn)
                eclipsed = 3;
            end
            
        end
        function importSP3Struct(this, sp3)
            this.time = sp3.time;
            this.coord =permute(sp3.coord,[3 2 1]);
            this.clock = sp3.clock',
            this.prn = sp3.prn;
            this.sys = sp3.sys;
            this.time_hr = sp3.time_hr;
            this.clock_hr = sp3.clock_hr;
            this.coord_rate = sp3.coord_rate;
            this.clock_rate = sp3.clock_rate;
            this.t_sun = sp3.t_sun;
            this.X_sun = sp3.X_sun';
            this.X_moon = sp3.X_moon';
            this.ERP = sp3.ERP;
            this.DCB = sp3.DCB;
            this.antenna_PCO = sp3.antPCO;
            this.start_time_idx = find(this.time == 1);
            
            
        end
        function load_antenna_PCV(this, filename_pco)
            antmod_S = this.cc.getAntennaId();
            this.antenna_PCV=read_antenna_PCV(filename_pco, antmod_S, this.time(1));
            this.antenna_PCO= zeros(1,size(this.antenna_PCV,2),3);
            this.satType = cell(1,size(this.antenna_PCV,2));
            if isempty(this.avail)
                this.avail=zeros(size(this.antenna_PCV,2),1)
            end
            for sat = 1 : size(this.antenna_PCV,2)
                if (this.antenna_PCV(sat).n_frequency ~= 0)
                    this.antenna_PCO(:,sat,:) = athis.antenna_PCV(sat).offset(:,:,1);
                    this.satType{1,sat} = this.antenna_PCV(sat).type;
                else
                    this.avail(sat) = 0;
                end
            end
        end
        function [stidecorr] = solid_earth_tide_correction(this, time, XR, XS, p_rate, phiC, lam)
            
            % SYNTAX:
            %   [stidecorr] = solid_earth_tide_correction(time, XR, XS,p_rate, phiC, lam);
            %
            % INPUT:
            %   time = GPS time
            %   XR   = receiver position  (X,Y,Z)
            %   XS   = satellite position (X,Y,Z)
            %   p_rate   = processing interval [s]
            %   phiC = receiver geocentric latitude (rad)
            %   lam  = receiver longitude (rad)
            %
            % OUTPUT:
            %   stidecorr = solid Earth tide correction terms (along the satellite-receiver line-of-sight)
            %
            % DESCRIPTION:
            %   Computation of the solid Earth tide displacement terms.
            
            
            if (nargin < 6)
                [~, lam, ~, phiC] = cart2geod(XR(1,1), XR(2,1), XR(3,1));
            end
            %north (b) and radial (c) local unit vectors
            b = [-sin(phiC)*cos(lam) -sin(phiC)*sin(lam) cos(phiC)];
            c = [+cos(phiC)*cos(lam) +cos(phiC)*sin(lam) sin(phiC)];
            
            %Sun and Moon position
            t_sun  = this.t_sun;
            X_sun  = this.X_sun;
            X_moon = this.X_moon;
            %[~, q] = min(abs(t_sun - time));
            % speed improvement of the above line
            % supposing t_sun regularly sampled
            q = round((time - t_sun(1)) / p_rate) + 1;
            X_sun  = X_sun(q,:);
            X_moon = X_moon(q,:);
            
            %receiver geocentric position
            XR_n = norm(XR);
            XR_u = XR / XR_n;
            
            %sun geocentric position
            X_sun_n = norm(X_sun);
            X_sun_u = X_sun / X_sun_n;
            
            %moon geocentric position
            X_moon_n = norm(X_moon);
            X_moon_u = X_moon / X_moon_n;
            
            %latitude dependence
            p = (3*sin(phiC)^2-1)/2;
            
            %gravitational parameters
            GE = goGNSS.GM_GAL; %Earth
            GS = GE*332946.0; %Sun
            GM = GE*0.01230002; %Moon
            
            %Earth equatorial radius
            R = 6378136.6;
            
            %nominal degree 2 Love number
            H2 = 0.6078 - 0.0006*p;
            %nominal degree 2 Shida number
            L2 = 0.0847 + 0.0002*p;
            
            %solid Earth tide displacement (degree 2)
            Vsun  = sum(conj(X_sun_u) .* XR_u);
            Vmoon = sum(conj(X_moon_u) .* XR_u);
            r_sun2  = (GS*R^4)/(GE*X_sun_n^3) *(H2*XR_u*(1.5*Vsun^2  - 0.5) + 3*L2*Vsun *(X_sun_u  - Vsun *XR_u));
            r_moon2 = (GM*R^4)/(GE*X_moon_n^3)*(H2*XR_u*(1.5*Vmoon^2 - 0.5) + 3*L2*Vmoon*(X_moon_u - Vmoon*XR_u));
            r = r_sun2 + r_moon2;
            
            %nominal degree 3 Love number
            H3 = 0.292;
            %nominal degree 3 Shida number
            L3 = 0.015;
            
            %solid Earth tide displacement (degree 3)
            r_sun3  = (GS*R^5)/(GE*X_sun_n^4) *(H3*XR_u*(2.5*Vsun^3  - 1.5*Vsun)  +   L3*(7.5*Vsun^2  - 1.5)*(X_sun_u  - Vsun *XR_u));
            r_moon3 = (GM*R^5)/(GE*X_moon_n^4)*(H3*XR_u*(2.5*Vmoon^3 - 1.5*Vmoon) +   L3*(7.5*Vmoon^2 - 1.5)*(X_moon_u - Vmoon*XR_u));
            r = r + r_sun3 + r_moon3;
            
            %from "conventional tide free" to "mean tide"
            radial = (-0.1206 + 0.0001*p)*p;
            north  = (-0.0252 + 0.0001*p)*sin(2*phiC);
            r = r + radial*c + north*b;
            
            %displacement along the receiver-satellite line-of-sight
            stidecorr = zeros(size(XS,1),1);
            for s = 1 : size(XS,1)
                LOS  = XR - XS(s,:);
                LOSu = LOS / norm(LOS);
                %stidecorr(s,1) = dot(r,LOSu);
                stidecorr(s,1) = sum(conj(r).*LOSu);
            end
        end
        function [poletidecorr] = pole_tide_correction(this, time, XR, XS, phiC, lam)
            
            % SYNTAX:
            %   [poletidecorr] = pole_tide_correction(time, XR, XS, SP3, phiC, lam);
            %
            % INPUT:
            %   time = GPS time
            %   XR   = receiver position  (X,Y,Z)
            %   XS   = satellite position (X,Y,Z)
            %   phiC = receiver geocentric latitude (rad)
            %   lam  = receiver longitude (rad)
            %
            % OUTPUT:
            %   poletidecorr = pole tide correction terms (along the satellite-receiver line-of-sight)
            %
            % DESCRIPTION:
            %   Computation of the pole tide displacement terms.
            if (nargin < 5)
                [~, lam, ~, phiC] = cart2geod(XR(1,1), XR(2,1), XR(3,1));
            end
            
            poletidecorr = zeros(size(XS,1),1);
            
            %interpolate the pole displacements
            if (~isempty(this.ERP))
                if (length(this.ERP.t) > 1)
                    m1 = interp1(this.ERP.t, this.ERP.m1, time, 'linear', 'extrap');
                    m2 = interp1(this.ERP.t, this.ERP.m2, time, 'linear', 'extrap');
                else
                    m1 = this.ERP.m1;
                    m2 = this.ERP.m2;
                end
                
                deltaR   = -33*sin(2*phiC)*(m1*cos(lam) + m2*sin(lam))*1e-3;
                deltaLam =  9* cos(  phiC)*(m1*sin(lam) - m2*cos(lam))*1e-3;
                deltaPhi = -9* cos(2*phiC)*(m1*cos(lam) + m2*sin(lam))*1e-3;
                
                corrENU(1,1) = deltaLam; %east
                corrENU(2,1) = deltaPhi; %north
                corrENU(3,1) = deltaR;   %up
                
                %displacement along the receiver-satellite line-of-sight
                XRcorr = local2globalPos(corrENU, XR);
                corrXYZ = XRcorr - XR;
                for s = 1 : size(XS,1)
                    LOS  = XR - XS(s,:)';
                    LOSu = LOS / norm(LOS);
                    poletidecorr(s,1) = -dot(corrXYZ,LOSu);
                end
            end
            
        end
        
        
        function writeSP3(this, f_name, prec)
            % SYNTAX:
            %   eph_tab.writeSP3(f_name, prec)
            %
            % INPUT:
            %   f_name       = file name of the sp3 file to be written
            %   prec        = precision (cm) of satellite orbit for all
            %   satellites (default 100)
            %
            %
            % DESCRIPTION:
            %   Write the current satellite postions and clocks bias into a sp3
            %   file
            if nargin<3
                prec=100;
            end
            %%% check if clock rate and coord rate are compatible
            rate_ratio=this.coord_rate/this.clock_rate;
            if abs(rate_ratio-round(rate_ratio)) > 0.00000001
                this.logger.addWarning(sprintf('Incompatible coord rate (%s) and clock rate (%s) , sp3 not produced',this.coord_rate,this.clock_rate))
                return
            end
            %%% check if sun and moon positions ahve been computed
            if isempty(this.X_sun) || this.X_sun(1,1)==0
                this.sun_moon_pos();
            end
            %%% compute center of mass position (X_sat - PCO)
            [sx ,sy, sz] = this.satellite_fixed_frameV(this.time,this.coord);
            temp_antPco=repmat(this.antenna_PCO,length(this.time),1,1);
            com_coord=this.coord - cat(3,sum(temp_antPco.*sx,3) , sum(temp_antPco.*sx,3) , sum(temp_antPco.*sx,3));
            clearvars temp_antPco
            %%% write to file
            rate_ratio = round(rate_ratio);
            fid=fopen(f_name,'w');
            this.writeHeader(fid, prec);
            
            for i=1:length(this.coord)
                this.writeEpoch(fid,[squeeze(com_coord(i,:,:)/1000) this.clock(:,(i-1)/rate_ratio+1)*1000000],i); %% convert coord in km and clock in microsecodns
            end
            fprintf(fid,'EOF\n');
            fclose(fid);
            
            
            
            
        end
        function writeHeader(this, fid, prec)
            
            if nargin<3
                prec=100,
            end
            prec = num2str(prec);
            time=this.time_ref.getCopy();
            time.addIntSeconds((1-this.time_zero_idx_coord)*900);
            str_time = time.toString();
            year = str2num(str_time(1:4));
            month = str2num(str_time(6:7));
            day = str2num(str_time(9:10));
            hour = str2num(str_time(12:13));
            minute = str2num(str_time(15:16));
            second = str2num(str_time(18:27));
            week = time.getGpsWeek();
            sow = time.getGpsTime()-week*7*86400;
            mjd = jd2mjd(cal2jd(year,month,day));
            d_frac = hour/24+minute/24*60+second/86400;
            step = this.coord_rate;
            num_epoch = length(this.time);
            cc = this.cc;
            fprintf(fid,'#cP%4i %2i %2i %2i %2i %11.8f %7i d+D   IGS14 CNV GReD\n',year,month,day,hour,minute,second,num_epoch);
            fprintf(fid,'## %4i %15.8f %14.8f %5i %15.13f\n',week,sow,step,mjd,d_frac);
            
            sats = [];
            pre = [];
            ids = cc.prn;
            for i = 1:length(ids)
                sats=[sats, strrep(sprintf('%s%2i', cc.system(i), ids(i)), ' ', '0')];
                pre=[pre, prec];
            end
            n_row=ceil(length(sats)/51);
            rows=cell(5,1);
            rows(:)={repmat('  0',1,17)};
            pres=cell(5,1);
            pres(:)={repmat('  0',1,17)};
            for i =1:n_row
                rows{i}=sats((i-1)*51+1:min(length(sats),i*51));
                pres{i}=pre((i-1)*51+1:min(length(pre),i*51));
            end
            last_row_length=length((i-1)*51+1:length(sats));
            rows{n_row}=[rows{n_row} repmat('  0',1,(51-last_row_length)/3)];
            pres{n_row}=[pres{n_row} repmat('  0',1,(51-last_row_length)/3)];
            
            fprintf(fid,'+   %2i   %s\n',sum(cc.n_sat),rows{1});
            for i=2:length(rows)
                fprintf(fid,'+        %s\n',rows{i});
            end
            for i=1:length(rows)
                fprintf(fid,'++       %s\n',pres{i});
            end
            fprintf(fid,'%%c M  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc\n');
            fprintf(fid,'%%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc\n');
            fprintf(fid,'%%f  1.2500000  1.025000000  0.00000000000  0.000000000000000\n');
            fprintf(fid,'%%f  0.0000000  0.000000000  0.00000000000  0.000000000000000\n');
            fprintf(fid,'%%i    0    0    0    0      0      0      0      0         0\n');
            fprintf(fid,'%%i    0    0    0    0      0      0      0      0         0\n');
            fprintf(fid,'/* Produced using goGPS                                     \n');
            fprintf(fid,'/*                 Non                                      \n');
            fprintf(fid,'/*                     Optional                             \n');
            fprintf(fid,'/*                              Lines                       \n');
        end
        function writeEpoch(this,fid,XYZT,epoch)
            t=this.time_ref.getCopy();
            t.addIntSeconds((e-this.time_zero_idx_coord)*900);
            cc=this.cc;
            str_time=t.toString();
            year=str2num(str_time(1:4));
            month=str2num(str_time(6:7));
            day=str2num(str_time(9:10));
            hour=str2num(str_time(12:13));
            minute=str2num(str_time(15:16));
            second=str2num(str_time(18:27));
            fprintf(fid,'*  %4i %2i %2i %2i %2i %11.8f\n',year,month,day,hour,minute,second);
            for i=1:size(XYZT,1)
                fprintf(fid,'P%s%14.6f%14.6f%14.6f%14.6f\n',strrep(sprintf('%s%2i', cc.system(i), cc.prn(i)), ' ', '0'),XYZT(i,1),XYZT(i,2),XYZT(i,3),XYZT(i,4));
            end
            
        end
        
        
        
    end
    
    
    methods (Static)
    end
end