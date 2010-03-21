<%!
    from sailfish import sym
%>

<%namespace file="code_common.mako" import="*"/>
<%namespace file="propagation.mako" import="rel_offset"/>

<%def name="noneq_bb(orientation)">
	case ${orientation}:
		%for arg, val in sym.noneq_bb(grid, orientation):
			${cex(arg, pointers=True)} = ${cex(val, pointers=True)};
		%endfor
		break;
</%def>

<%def name="zouhe_fixup(orientation)">
	case ${orientation}:
		%for arg, val in sym.zouhe_fixup(grid, orientation):
			${str(arg)} = ${cex(val)};
		%endfor
		break;
</%def>

<%def name="get_boundary_velocity(node_type, mx, my, mz, rho=0, moments=False)">
	int idx = (${node_type} - GEO_BCV) * ${dim};
	%if moments:
		${mx} = geo_params[idx] * ${rho};
		${my} = geo_params[idx+1] * ${rho};
		%if dim == 3:
			${mz} = geo_params[idx+2] * ${rho};
		%endif
	%else:
		${mx} = geo_params[idx];
		${my} = geo_params[idx+1];
		%if dim == 3:
			${mz} = geo_params[idx+2];
		%endif
	%endif
</%def>

<%def name="get_boundary_pressure(node_type, rho)">
	int idx = (GEO_BCP-GEO_BCV) * ${dim} + (${node_type} - GEO_BCP);
	${rho} = geo_params[idx] * 3.0f;
</%def>

<%def name="get_boundary_params(node_type, mx, my, mz, rho, moments=False)">
	if (${node_type} >= GEO_BCV) {
		// Velocity boundary condition.
		if (${node_type} < GEO_BCP) {
			${get_boundary_velocity(node_type, mx, my, mz, rho, moments)}
		// Pressure boundary condition.
		} else {
			${get_boundary_pressure(node_type, rho)}
		}
	}
</%def>

<%def name="fill_missing_distributions()">
	switch (orientation) {
		%for i in range(1, grid.dim*2+1):
			case ${i}: {
				%for lvalue, rvalue in sym.fill_missing_dists(grid, 'fi', missing_dir=i):
					${lvalue} = ${rvalue};
				%endfor
				break;
			}
		%endfor
	}
</%def>

<%def name="external_force(node_type, vx, vy, vz, rho=0, momentum=False)">
	%if ext_accel_x != 0.0 or ext_accel_y != 0.0 or ext_accel_z != 0.0:
		if (!isWallNode(${node_type})) {
			%if momentum:
				%if ext_accel_x != 0.0:
					${vx} += ${rho} * ${'%.20ff' % (0.5 * ext_accel_x)};
				%endif
				%if ext_accel_y != 0.0:
					${vy} += ${rho} * ${'%.20ff' % (0.5 * ext_accel_y)};
				%endif
				%if dim == 3 and ext_accel_z != 0.0:
					${vz} += ${rho} * ${'%.20ff' % (0.5 * ext_accel_z)};
				%endif
			%else:
				%if ext_accel_x != 0.0:
					${vx} += ${'%.20ff' % (0.5 * ext_accel_x)};
				%endif
				%if ext_accel_y != 0.0:
					${vy} += ${'%.20ff' % (0.5 * ext_accel_y)};
				%endif
				%if dim == 3 and ext_accel_z != 0.0:
					${vz} += ${'%.20ff' % (0.5 * ext_accel_z)};
				%endif
			%endif
		}
	%endif
</%def>

${device_func} inline void bounce_back(Dist *fi)
{
	float t;

	%for i in sym.bb_swap_pairs(grid):
		t = fi->${grid.idx_name[i]};
		fi->${grid.idx_name[i]} = fi->${grid.idx_name[grid.idx_opposite[i]]};
		fi->${grid.idx_name[grid.idx_opposite[i]]} = t;
	%endfor
}

<%def name="get_field_off(xoff, yoff, zoff)">
	off = ${rel_offset(xoff, yoff, zoff)};
	nx = x + ${xoff};
	ny = y + ${yoff};
	nz = z + ${zoff};

	%if periodicity[0] and xoff != 0:
		if (nx < 0 || nx > ${lat_nx-1})
			off += ${pbc_offsets[0][int(xoff)]};
	%endif

	%if periodicity[1] and yoff != 0:
		if (ny < 0 || ny > ${lat_ny-1})
			off += ${pbc_offsets[1][int(yoff)]};
	%endif

	%if periodicity[2] and zoff != 0:
		if (nz < 0 || nz > ${lat_nz-1})
			off += ${pbc_offsets[2][int(zoff)]};
	%endif
</%def>

${device_func} inline void laplacian_and_grad(${global_ptr} float *field, int i, float *laplacian, float *grad, int x, int y, int z)
{
	int off, nx, ny, nz;

	${get_field_off(+1, 0, 0)}	float fe = field[i + off];
	${get_field_off(-1, 0, 0)}	float fw = field[i + off];
	${get_field_off(0, +1, 0)}	float fn = field[i + off];
	${get_field_off(0, -1, 0)}	float fs = field[i + off];
%if dim == 3:
	${get_field_off(0, 0, +1)}	float ft = field[i + off];
	${get_field_off(0, 0, -1)}	float fb = field[i + off];
%endif

%if dim == 2:
	laplacian[0] = fe + fw + fn + fs - 4.0f * field[i];
%else:
	laplacian[0] = fe + fw + fn + fs + ft + fb - 6.0f * field[i];
%endif

	grad[0] = (fe - fw) / 2.0f;
	grad[1] = (fn - fs) / 2.0f;
%if dim == 3:
	grad[2] = (ft - fb) / 2.0f;
%endif
}

<%doc>
// More sophisticated finite difference formulas optimized to minimize spurious velocities
// at the surface of a spherical drop.  Fomulas taken from:
//   PRE 77, 046702 (2008)
${device_func} inline void laplacian_and_grad(${global_ptr} float *field, int i, float *laplacian, float *grad, int x, int y, int z)
{
	int off, nx, ny, nz;

	${get_field_off(+1, 0, 0)}	float fe = field[i + off];
	${get_field_off(-1, 0, 0)}	float fw = field[i + off];
	${get_field_off(0, +1, 0)}	float fn = field[i + off];
	${get_field_off(0, -1, 0)}	float fs = field[i + off];
	${get_field_off(+1, +1, 0)}	float fne = field[i + off];
	${get_field_off(-1, +1, 0)}	float fnw = field[i + off];
	${get_field_off(+1, -1, 0)}	float fse = field[i + off];
	${get_field_off(-1, -1, 0)}	float fsw = field[i + off];

%if dim == 3:
	${get_field_off(0, 0, +1)}	float ft = field[i + off];
	${get_field_off(0, 0, -1)}	float fb = field[i + off];
	${get_field_off(+1, 0, +1)}	float fte = field[i + off];
	${get_field_off(-1, 0, +1)}	float ftw = field[i + off];
	${get_field_off(+1, 0, -1)}	float fbe = field[i + off];
	${get_field_off(-1, 0, -1)}	float fbw = field[i + off];
	${get_field_off(0, +1, +1)}	float ftn = field[i + off];
	${get_field_off(0, -1, +1)}	float fts = field[i + off];
	${get_field_off(0, +1, -1)}	float fbn = field[i + off];
	${get_field_off(0, -1, -1)}	float fbs = field[i + off];

	grad[0] = (-fnw - fsw - ftw - fbw + fse + fne + fte + fbe) / 12.0f + (fe - fw) / 6.0f;
	grad[1] = (-fse - fsw - fts - fbs + fne + fnw + ftn + fbn) / 12.0f + (fn - fs) / 6.0f;
	grad[2] = (-fbe - fbw - fbn - fbs + fte + ftw + ftn + fts) / 12.0f + (ft - fb) / 6.0f;
	laplacian[0] = (fnw + fne + fse + fsw + fte + ftw + ftn + fts + fbe + fbw + fbn + fbs) / 6.0f  + (ft + fb + fe + fw + fn + fs) / 3.0f - 4.0f * field[i];
%else:
	grad[0] = (-fnw - fsw + fse + fne) / 12.0f + (fe - fw) / 3.0f;
	grad[1] = (-fse - fsw + fne + fnw) / 12.0f + (fn - fs) / 3.0f;
	laplacian[0] = fnw + fne + fsw + fse + 4.0f * (fe + fw + fn + fs) - 20.0f * field[0];
%endif
}
</%doc>

<%def name="sc_potential(comp)">
	f${comp}[i + off]
##	1.0f - exp(-f${comp}[i + off])
</%def>

%if simtype == 'shan-chen':
${device_func} inline void shan_chen_accel(int i, ${global_ptr} float *f1, ${global_ptr} float *f2, float *a1, float *a2, int x, int y)
{
	float t1, t2;

	%for i in range(0, dim):
		a1[${i}] = 0.0f;
		a2[${i}] = 0.0f;
	%endfor

	int off, nx, ny;

	%for i, ve in enumerate(grid.basis):
		%if dim == 3:
			t1 = 1.0f - expf(-f1[i + ${rel_offset(ve[0], ve[1], ve[2])}]);
			t2 = 1.0f - expf(-f2[i + ${rel_offset(ve[0], ve[1], ve[2])}]);
		%else:

			off = ${rel_offset(ve[0], ve[1], 0)};
			nx = x + ${ve[0]};
			ny = y + ${ve[1]};

			%if periodicity[0] and ve[0] != 0:
				if (nx < 0 || nx > ${lat_nx-1}) {
					off += ${pbc_offsets[0][int(ve[0])]};
				}
			%endif

			%if periodicity[1] and ve[1] != 0:
				if (ny < 0 || ny > ${lat_ny-1}) {
					off += ${pbc_offsets[1][int(ve[1])]};
				}
			%endif

			t1 = ${sc_potential(1)};
			t2 = ${sc_potential(2)};
		%endif

		%if ve[0] != 0:
			a1[0] += t2 * ${ve[0] * grid.weights[i]};
			a2[0] += t1 * ${ve[0] * grid.weights[i]};
		%endif
		%if ve[1] != 0:
			a1[1] += t2 * ${ve[1] * grid.weights[i]};
			a2[1] += t1 * ${ve[1] * grid.weights[i]};
		%endif
		%if dim == 3 and ve[2] != 0:
			a1[2] += t2 * ${ve[2] * grid.weights[i]};
			a2[2] += t1 * ${ve[2] * grid.weights[i]};
		%endif
	%endfor

	off = 0;

	t1 = ${sc_potential(1)};
	t2 = ${sc_potential(2)};

	%for i in range(0, dim):
		a1[${i}] *= t1 * SCG;
		a2[${i}] *= t2 * SCG;
	%endfor
}
%endif

// Compute the 0th moment of the distributions, i.e. density.
${device_func} inline void compute_0th_moment(Dist *fi, float *out)
{
	*out = ${sym.ex_rho(grid, 'fi', incompressible)};
}

// Compute the 1st moments of the distributions, i.e. momentum.
${device_func} inline void compute_1st_moment(Dist *fi, float *out, int add, float factor)
{
	if (add) {
		%for d in range(0, grid.dim):
			out[${d}] += factor * (${cex(sym.ex_velocity(grid, 'fi', d, momentum=True), pointers=True)});
		%endfor
	} else {
		%for d in range(0, grid.dim):
			out[${d}] = factor * (${cex(sym.ex_velocity(grid, 'fi', d, momentum=True), pointers=True)});
		%endfor
	}
}

// Compute the 1st moments of the distributions and divide it by the 0-th moment
// i.e. compute velocity.
${device_func} inline void compute_1st_div_0th(Dist *fi, float *out, float zero)
{
	%for d in range(0, grid.dim):
		out[${d}] = ${cex(sym.ex_velocity(grid, 'fi', d), pointers=True, rho='zero')};
	%endfor
}

${device_func} inline void compute_macro_quant(Dist *fi, float *rho, float *v)
{
	compute_0th_moment(fi, rho);
	compute_1st_div_0th(fi, v, *rho);
}

%if bc_wall == 'zouhe' or bc_velocity == 'zouhe' or bc_pressure == 'zouhe':
${device_func} void zouhe_bb(Dist *fi, int orientation, float *rho, float *v0)
{
	// Bounce-back of the non-equilibrium parts.
	switch (orientation) {
		%for i in range(1, grid.dim*2+1):
			${noneq_bb(i)}
		%endfor
		case ${geo_dir_other}:
			bounce_back(fi);
			return;
	}

	float nvx, nvy;
	%if dim == 3:
		float nvz;
	%endif

	// Compute new macroscopic variables.
	nvx = ${cex(sym.ex_velocity(grid, 'fi', 0, momentum=True))};
	nvy = ${cex(sym.ex_velocity(grid, 'fi', 1, momentum=True))};
	%if dim == 3:
		nvz = ${cex(sym.ex_velocity(grid, 'fi', 2, momentum=True))};
	%endif

	// Compute momentum difference.
	nvx = *rho * v0[0] - nvx;
	nvy = *rho * v0[1] - nvy;
	%if dim == 3:
		nvz = *rho * v0[2] - nvz;
	%endif

	switch (orientation) {
		%for i in range(1, grid.dim*2+1):
			${zouhe_fixup(i)}
		%endfor
	}
}
%endif

## TODO integrate it via mako with the function below

${device_func} inline void get0thMoment(Dist *fi, int node_type, int orientation, float *out)
{
	compute_0th_moment(fi, out);
}

//
// Get macroscopic density rho and velocity v given a distribution fi, and
// the node class node_type.
//
${device_func} inline void getMacro(Dist *fi, int node_type, int orientation, float *rho, float *v)
{
	if (isFluidOrWallNode(node_type) || orientation == ${geo_dir_other}) {
		compute_macro_quant(fi, rho, v);
		if (isWallNode(node_type)) {
			v[0] = 0.0f;
			v[1] = 0.0f;
			%if dim == 3:
				v[2] = 0.0f;
			%endif
			%if bc_wall == 'zouhe':
				zouhe_bb(fi, orientation, rho, v);
			%endif
		}
	} else if (isVelocityNode(node_type)) {
		%if bc_velocity == 'zouhe':
			*rho = ${sym.ex_rho(grid, 'fi', incompressible)};
			${get_boundary_velocity('node_type', 'v[0]', 'v[1]', 'v[2]')}
			zouhe_bb(fi, orientation, rho, v);
		// We're dealing with a boundary node, for which some of the distributions
		// might be meaningless.  Fill them with the values of the opposite
		// distributions.
		%elif bc_velocity == 'equilibrium':
			${fill_missing_distributions()}
			*rho = ${sym.ex_rho(grid, 'fi', incompressible)};
			${get_boundary_velocity('node_type', 'v[0]', 'v[1]', 'v[2]')}

			switch (orientation) {
				%for i in range(1, grid.dim*2+1):
					case ${i}:
						*rho = ${cex(sym.ex_rho(grid, 'fi', incompressible, missing_dir=i), pointers=True)};
						break;
				%endfor
			}
		%else:
			compute_macro_quant(fi, rho, v0);
		%endif
	} else if (isPressureNode(node_type)) {
		%if bc_pressure == 'zouhe' or bc_pressure == 'equilibrium':
			${fill_missing_distributions()}
			*rho = ${sym.ex_rho(grid, 'fi', incompressible)};
			float par_rho;
			${get_boundary_pressure('node_type', 'par_rho')}

			switch (orientation) {
				%for i in range(1, grid.dim*2+1):
					case ${i}: {
						%for d in range(0, grid.dim):
							v[${d}] = ${cex(sym.ex_velocity(grid, 'fi', d, missing_dir=i, par_rho='par_rho'), pointers=True)};
						%endfor
						break;
					 }
				%endfor
			}

			%if bc_pressure == 'zouhe':
				zouhe_bb(fi, orientation, &par_rho, v);
				compute_macro_quant(fi, rho, v);
			%endif
			*rho = par_rho;
		%else:
			compute_macro_quant(fi, rho, v);
		%endif
	}

	%if simtype == 'fluid':
		${external_force('node_type', 'v0[0]', 'v0[1]', 'v0[2]')}
	%endif
}

${device_func} inline void boundaryConditions(Dist *fi, int node_type, int orientation, float *rho, float *v)
{
	%if bc_wall == 'fullbb':
		if (isWallNode(node_type)) {
			bounce_back(fi);
		}
	%endif

	%if bc_velocity == 'fullbb':
		if (isVelocityNode(node_type)) {
			bounce_back(fi);
			${get_boundary_velocity('node_type', 'v[0]', 'v[1]', 'v[2]')}
			%for i, ve in enumerate(grid.basis):
				fi->${grid.idx_name[i]} += ${cex(
					sim.S.rho0 * 2 * grid.weights[i] * grid.v.dot(ve) / grid.cssq, pointers=True)};
			%endfor
			*rho = ${sym.ex_rho(grid, 'fi', incompressible)};
		}
	%endif

	%if bc_velocity == 'equilibrium' or bc_pressure == 'equilibrium':
		%for local_var in bgk_equilibrium_vars:
			float ${cex(local_var.lhs)} = ${cex(local_var.rhs)};
		%endfor
	%endif

	%if bc_velocity == 'equilibrium':
		if (isVelocityNode(node_type)) {
			%for eq in bgk_equilibrium:
				%for feq, idx in eq:
					fi->${idx} = ${cex(feq, pointers=True)};
				%endfor
			%endfor
		}
	%endif

	%if bc_pressure == 'equilibrium':
		if (isPressureNode(node_type)) {
			%for eq in bgk_equilibrium:
				%for feq, idx in eq:
					fi->${idx} = ${cex(feq, pointers=True)};
				%endfor
			%endfor
		}
	%endif
}

