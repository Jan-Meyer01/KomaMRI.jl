##########################
## SIMULATION FUNCTIONS ##
##########################

"""Divides a list of indices 1:N in k groups"""
function kfoldperm(N,k; type="random")
	n,r = divrem(N,k)
	b = collect(1:n:N+1)
	for i in 1:length(b)
		b[i] += i > r ? r : i-1
	end
	if type=="random"
		p = randperm(N)
	elseif type=="ordered"
		p = 1:N
	end
	return [p[r] for r in [b[i]:b[i+1]-1 for i=1:k]]
end

#GPU related functions
gpu(x) = has_cuda() ? CuArray(x) : x
print_gpus() = begin
	println( "$(length(devices())) CUDA capable device(s)." )
	for d = devices()
		println( "  - "*name(d) )
	end
end
print_gpus_info() = begin
	@info "$(length(devices())) CUDA capable device(s)."
	for d = devices()
		@info "  - "*name(d) 
	end
end

"""
	run_spin_precession(obj,seq,t)

Simulates an MRI sequence `seq` on the Phantom `obj` for time points `t`.
It calculates S(t) = ∫ ρ(x,t) exp(- t/T2(x,t) ) exp(- 𝒊 ϕ(x,t)) dx.
"""
function run_spin_precession(obj::Phantom, seq::Sequence, t::Array{Float64,1};
	M0::Array{Mag,1})

	𝒊 = 1im; Random.seed!(1)
	t = reshape(t,1,length(t)); Δt = t[2]-t[1]
    sz = size(obj)
	Nsz, Nt = length(sz), length(t)
	ϕ0 = angle.(M0) #<-----------CHANGE TO USE MAGNETIZATION M0
	
	#DIFFUSION
	# if !all(obj.Dλ1 .== 0) && !all(obj.Dλ2 .== 0) #No diff optimization
	# 	#TODO: I need to add diff displacement η story between blocks (like ϕ0)
	# 	η1 = randn(sz...,Nt) |> gpu
	# 	η2 = randn(sz...,Nt) |> gpu
	# 	Dθ = obj.Dθ |> gpu
	# 	Dλ1 = obj.Dλ1 |> gpu
	# 	Dλ2 = obj.Dλ2 |> gpu
	# 	ηx = sqrt.(2Δt .* Dλ1) .* η1 |> gpu
	# 	ηy = sqrt.(2Δt .* Dλ2) .* η2 |> gpu
	# 	ηxp = cumsum(ηx .* cos.(Dθ) .- ηy.*sin.(Dθ), dims=Nsz+1) |> gpu
	# 	ηyp = cumsum(ηy .* cos.(Dθ) .+ ηx.*sin.(Dθ), dims=Nsz+1) |> gpu
	# else
		ηxp = 0
		ηyp = 0
	# end
	#SCANNER
    Gx, Gy = get_grads(seq,t)
	Gx = Gx |> gpu
	Gy = Gy |> gpu 
	#SIMULATION
	ϕ0 = ϕ0    |> gpu
	x0 = obj.x |> gpu
	y0 = obj.y |> gpu
	t = t	   |> gpu
    xt = x0 .+ obj.ux(x0,y0,0,t) .+ ηxp |> gpu
	yt = y0 .+ obj.uy(x0,y0,0,t) .+ ηyp |> gpu
	#ACQ OPTIMIZATION
    if is_DAC_on(seq, Array(t)) 
		ϕ = ϕ0 .+ (2π*γ).*cumsum((xt.*Gx.+yt.*Gy).*Δt, dims=Nsz+1) 
	else
		ϕ = ϕ0 .+ (2π*γ).*sum((xt.*Gx.+yt.*Gy).*Δt, dims=Nsz+1) 
	end
	#SIGNAL
	ρ = obj.ρ	 |> gpu
	Δw = obj.Δw  |> gpu
	T2 = obj.T2  |> gpu
	S = sum(ρ.*exp.(-𝒊.*(ϕ .+ Δw.*t) .- t./T2 ), dims=1:Nsz)[:]
	#Signal; Current magnetization
	ϕ0 = Array(ϕ[:,end])
    Array(S), Mag.(exp.(ϕ0*𝒊), 1)
end

"""
Implementation in multiple threads. Separating the spins in N_parts.
"""
function run_spin_precession_parallel(obj::Phantom,seq::Sequence,t::Array{Float64,1};
	M0::Array{Mag,1}, N_parts::Int=has_cuda() ? 1 : Threads.nthreads())

	Nt, Ns = length(t), prod(size(obj))
	S = zeros(ComplexF64, Nt)
	
	parts = kfoldperm(Ns, N_parts, type="ordered") 

	@threads for p ∈ parts
		aux, M0[p] = run_spin_precession(obj[p],seq,t; M0=M0[p])
		S .+= aux
		aux = nothing
	end
    S, M0
end

run_spin_excitation_parallel(obj, seq, t; M0) = begin
	# #SCANNER
	# B1 = get_rfs(seq,t)
    # Gx, Gy = get_grads(seq,t)
	# Gx = Gx |> gpu
	# Gy = Gy |> gpu 
	# #SIMULATION
	# ϕ0 = ϕ0    |> gpu
	# x0 = obj.x |> gpu
	# y0 = obj.y |> gpu
	# t = t	   |> gpu
    # xt = x0 .+ obj.ux(x0,y0,t) .+ ηxp |> gpu
	# yt = y0 .+ obj.uy(x0,y0,t) .+ ηyp |> gpu

	# φ = -2π*γ * ΔT .* sqrt.(abs.(B1e).^2 .+ abs.(Bz).^2) # angle of rotation 
	# φ[φ.==0] .= 1e-17; # removes problems when dividing by φ
	# n =  2π*γ * ΔT .* [Bx By Bz]./abs.(φ) # axis of rotation
	# Qs = [Q(φ[i],n[i,:]) for i=1:N] # hard-pulse approximation for every RF element in RFs
	# Qt = *(Qs...) # Total rotation matrix

	M0
end

#TODO: Create function that handles Array{Sequence,1}, starting where the other one ended

"""Divides time steps in N_parts blocks. Decreases RAM usage in long sequences."""
function run_sim2D_times_iter(obj::Phantom,seq::Sequence, t::Array{Float64,1}; N_parts::Int=16)
	if N_parts != 1
		@warn "Diffusion will not be simulated correctly with `N_parts != 1` inside function `run_sim2D_times_iter()`.  This is a known bug being fixed."
	end

	N, Ns = length(t), prod(size(obj))
	S = zeros(ComplexF64, N)
	M0 = Mag(obj) #Magnetization initialization

    parts = kfoldperm(N,N_parts,type="ordered")
	println("Starting simulation with Nspins=$Ns and Nt=$N")
	
	#TODO: transform suceptibility χ to Δω, for each time-block.
	@showprogress for p ∈ parts
		if is_RF_on(seq, t[p])
			M0 =  run_spin_excitation_parallel(obj, seq, t[p]; M0)
		else
			S[p], M0 =  run_spin_precession_parallel(obj, seq, t[p]; M0)
		end
	end
	S
	#TODO: output raw data in ISMRMD format
	#S[MRIsim.get_DAC_on(seq,t)]/prod(size(phantom)) #Acquired data <---- 
end