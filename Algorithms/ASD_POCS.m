function [ fres ] = ASD_POCS(proj,geo,angles,maxiter,varargin)
%ASD_POCS Solves the ASD_POCS total variation constrained image in 3D
% tomography. 
% 
%   ASD_POCS(PROJ,GEO,ALPHA,NITER) solves the reconstruction problem
%   using the projection data PROJ taken over ALPHA angles, corresponding
%   to the geometry descrived in GEO, using NITER iterations.
%
%   ASD_POCS(PROJ,GEO,ALPHA,NITER,OPT,VAL,...) uses options and values for solving. The
%   possible options in OPT are:
%
%
%   'lambda':      Sets the value of the hyperparameter for the SART iterations. 
%                  Default is 1
%
%   'lambdared':   Reduction of lambda.Every iteration
%                  lambda=lambdared*lambda. Default is 0.99
%
%   'TViter':      Defines the amount of TV iterations performed per SART
%                  iteration. Default is 20
%
%   'alpha':       Defines the TV hyperparameter. default is 0.002
% 
%   'alpha_red':   Defines the reduction rate of the TV hyperparameter
%
%   'Ratio':       The maximum allowed image/TV update ration. If the TV 
%                  update changes the image more than this, the parameter
%                  will be reduced.default is 0.95
%   'maxL2err'     Maximum L2 error to accept an image as valid. This
%                  parameter is crucial for the algorithm, determines at
%                  what point an image should not be updated further.
%                  Default is 20% of the FDK L2 norm.
%   'Verbose'      1 or 0. Default is 1. Gives information about the
%                  progress of the algorithm.

%% parse inputs
[beta,beta_red,ng,verbose,alpha,alpha_red,rmax,epsilon]=parse_inputs(proj,geo,angles,varargin);




%% Create weigthing matrices for the SART step
% the reason we do this, instead of calling the SART fucntion is not to
% recompute the weigths every ASD-POCS iteration, thus effectively doubling
% the computational time
% Projection weigth, W
W=Ax(ones(geo.nVoxel'),geo,angles); %To get the length of the x-ray inside the object domain
W(W<min(geo.dVoxel)/4)=Inf;
W=1./W;
% Back-Projection weigth, V
[x,y]=meshgrid(geo.sVoxel(1)/2-geo.dVoxel(1)/2+geo.offOrigin(1):-geo.dVoxel(1):-geo.sVoxel(1)/2+geo.dVoxel(1)/2+geo.offOrigin(1),...
    -geo.sVoxel(2)/2+geo.dVoxel(2)/2+geo.offOrigin(2): geo.dVoxel(2): geo.sVoxel(2)/2-geo.dVoxel(2)/2+geo.offOrigin(2));
A = permute(angles+pi/2, [1 3 2]);
V = (geo.DSO ./ (geo.DSO + bsxfun(@times, y, sin(-A)) - bsxfun(@times, x, cos(-A)))).^2;
clear A x y dx dz;


% initialize image.
f=zeros(geo.nVoxel');


stop_criteria=0;
iter=0;
offOrigin=geo.offOrigin;
offDetector=geo.offDetector;
while ~stop_criteria %POCS
    f0=f;
    if (iter==0 && verbose==1);tic;end
    iter=iter+1;
    for jj=1:length(angles);
        if size(offOrigin,2)==length(angles)
            geo.OffOrigin=offOrigin(:,jj);
        end
        if size(offDetector,2)==length(angles)
            geo.offDetector=offDetector(:,jj);
        end
        proj_err=proj(:,:,jj)-Ax(f,geo,angles(jj));          %                                 (b-Ax)
        weighted_err=W(:,:,jj).*proj_err;                   %                          W^-1 * (b-Ax)
        backprj=Atb(weighted_err,geo,angles(jj));            %                     At * W^-1 * (b-Ax)
        weigth_backprj=bsxfun(@times,1./V(:,:,jj),backprj); %                 V * At * W^-1 * (b-Ax)
        f=f+beta*weigth_backprj;                          % x= x + lambda * V * At * W^-1 * (b-Ax)
        % Enforce positivity
        f(f<0)=0;
    end
    
    geo.offDetector=offDetector;
    geo.offOrigin=offOrigin;
    % Save copy of image.
    fres=f;
    % compute L2 error of actual image. Ax-b
    g=Ax(f,geo,angles);
    dd=im3Dnorm(g-proj,'L2');
    % compute change in the image after last SART iteration
    dp_vec=(f-f0);
    dp=im3Dnorm(dp_vec,'L2');
    
    if iter==1
        dtvg=alpha*dp;
        %Convert the steepest-descent step-size from a fraction of a
        %step-size to an absolute image distance on the first iteration.
    end
    f0=f;
    
    %  TV MINIMIZATION
    % =========================================================================
    %  Call GPU to minimize TV
%     f=minimizeTV(f0,dtvg,ng);    %   This is the MATLAB CODE, the functions are sill in the library, but CUDA is used nowadays
                                            for ii=1:ng
%                                                 Steepest descend of TV norm
                                                tv(ng*(iter-1)+ii)=im3Dnorm(f,'TV','forward');
                                                df=gradientTVnorm(f,'forward');
                                                df=df./im3Dnorm(df,'L2');
                                                f=f-dtvg.*df;
                                            end
    
    % update parameters
    % ==========================================================================
    
    % compute change by TV min
    dg_vec=(f-f0);
    dg=im3Dnorm(dg_vec,'L2');
    % if change in TV is bigger than the change in SART AND image error is still bigger than acceptable
    if dg>rmax*dp && dd>epsilon
        dtvg=dtvg*alpha_red;
    end
    % reduce SART step
    beta=beta*beta_red;
    % Check convergence criteria
    % ==========================================================================
    
    %Define c_alpha as in equation 21 in the journal
    c=dot(dg_vec(:),dp_vec(:))/(norm(dg_vec(:),2)*norm(dp_vec(:),2));
    %This c is examined to see if it is close to -1.0
    
    if (c<-0.99 && dd<=epsilon) || beta<0.005|| iter>maxiter
        if verbose
            disp(['Stopping criteria met']);
            disp(['   c    = ' num2str(c)]);
            disp(['   beta = ' num2str(beta)]);
            disp(['   iter = ' num2str(iter)]);
        end
        stop_criteria=true;
    end
    if (iter==1 && verbose==1);
        expected_time=toc*maxiter;
        disp('ADS-POCS');
        disp(['Expected duration  :    ',secs2hms(expected_time)]);
        disp(['Exected finish time:    ',datestr(datetime('now')+seconds(expected_time))]);
        disp('');
    end
    
end



end

function [beta,beta_red,ng,verbose,alpha,alpha_red,rmax,epsilon]=parse_inputs(proj,geo,angles,argin)

opts=     {'lambda','lambda_red','TViter','Verbose','alpha','alpha_red','Ratio','maxL2err'};
defaults=ones(length(opts),1);
% Check inputs
nVarargs = length(argin);
if mod(nVarargs,2)
    error('CBCT:ASD_POCS:InvalidInput','Invalid number of inputs')
end

% check if option has been passed as input
for ii=1:2:nVarargs
    ind=find(ismember(opts,argin{ii}));
    if ~isempty(ind)
        defaults(ind)=0;
    end
end

for ii=1:length(opts)
    opt=opts{ii};
    default=defaults(ii);
    % if one option isnot default, then extract value from input
    if default==0
        ind=double.empty(0,1);jj=1;
        while isempty(ind)
            ind=find(isequal(opt,argin{jj}));
            jj=jj+1;
        end
        val=argin{jj};
    end
    % parse inputs
    switch opt
        % Verbose
        %  =========================================================================
        case 'Verbose'
            if default
                verbose=1;
            else
                verbose=val;
            end
            % Lambda
            %  =========================================================================
            % Its called beta in ASD-POCS
        case 'lambda'
            if default
                beta=1;
            else
                if length(val)>1 || ~isnumeric( val)
                    error('CBCT:ASD_POCS:InvalidInput','Invalid lambda')
                end
                beta=val;
            end
            % Lambda reduction
            %  =========================================================================
        case 'lambda_red'
            if default
                beta_red=0.99;
            else
                if length(val)>1 || ~isnumeric( val)
                    error('CBCT:ASD_POCS:InvalidInput','Invalid lambda')
                end
                beta_red=val;
            end
            % Number of iterations of TV
            %  =========================================================================
        case 'TViter'
            if default
                ng=20;
            else
                ng=val;
            end
            %  TV hyperparameter
            %  =========================================================================
        case 'alpha'
            if default
                alpha=0.002; % 0.2
            else
                alpha=val;
            end
            %  TV hyperparameter redution
            %  =========================================================================
        case 'alpha_red'
            if default
                alpha_red=0.95;
            else
                alpha_red=val;
            end
            %  Maximum update ratio 
            %  =========================================================================            
        case 'Ratio'
            if default
                rmax=0.95;
            else
                rmax=val;
            end
            %  Maximum L2 error to have a "good image"
            %  =========================================================================       
        case 'maxL2err'
            if default
               epsilon=im3Dnorm(FDK(proj,geo,angles))*0.2; %heuristic
            else
               epsilon=val;
            end
        otherwise
             error('CBCT:ASD_POCS:InvalidInput',['Invalid input name:', num2str(opt),'\n No such option in ASD_POCS()']);
    
    end
end

end




