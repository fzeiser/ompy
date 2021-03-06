# -*- coding: utf-8 -*-
# cython: profile=True
"""
Script to decompose the frist generations matrix P
into the NLD $\rho$ and transmission coefficient $T$
(or $\gamma$-ray strength function $gsf$) respectivly

to compile, run following:
cython3 rhosig.pyx
gcc -shared -pthread -fPIC -fwrapv -O2 -Wall -fno-strict-aliasing -I/usr/include/python3.5 -o rhosig.so rhosig.c

Copyright (C) 2018 Fabio Zeiser
University of Oslo
fabiobz [0] fys.uio.no

Slightly modified by Jørgen Eriksson Midtbø and implemented into
oslo_method_python.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
"""


import numpy as np
import matplotlib.pyplot as plt
from scipy.optimize import minimize
from uncertainties import unumpy

from .spinfunctions import SpinFunctions
from .matrix import Matrix
from .library import div0

cimport cython
cimport numpy as np

# TODO: Move this into the function call
# normalization of the gsf
# choose a spincut model and give it's parameters


# cdef np.ndarray Js = np.array([3, 4, 5]) # Hacky test of beta-Oslo spin range. No effect?

def spin_dist(Ex, J, spincutModel, spincutPars):
    return SpinFunctions(Ex=Ex, J=J,
                         model=spincutModel,
                         pars=spincutPars).distibution()


def z(np.ndarray Exarr, np.ndarray Egarr, spin_dist_par=None):
    cdef np.ndarray z
    cdef float inner_sum
    cdef list Jfs
    cdef float g_pop
    cdef int ji
    cdef int jf
    cdef int i_Ex, i_Eg
    cdef float Ex, Eg

    # If no spin distribution parameters are specified, use some defaults:
    # (TODO: This could be made nicer, but let's get some use experience first)
    if spin_dist_par is None:
        spin_dist_par = {
            # some dummy values:
            "spincutModel": "EB05",
            "spincutPars": {"mass": 164, "NLDa": 25.16, "Eshift": 0.12},
            "Jmax": 20
        }

    cdef np.ndarray Js = np.linspace(0, spin_dist_par["Jmax"],
                                     spin_dist_par["Jmax"]+1)

    z = np.zeros((len(Exarr), len(Egarr)))

    for i_Ex, Ex in enumerate(Exarr):
        for i_Eg, Eg in enumerate(Egarr):
            if Ex-Eg <= 0:
                continue
            for ji in Js:
                if ji==0:
                    Jfs = [1]
                else:
                    Jfs = [ji-1, ji, ji+1]
                # assume g_pop propto g_int
                # TODO: should the 1/2 be there?
                g_pop = 1./2. * spin_dist(Ex, ji,
                                          spin_dist_par["spincutModel"],
                                          spin_dist_par["spincutPars"]
                                          )
                inner_sum = 0
                for jf in Jfs:
                    # TODO: should the 1/2 be there?
                    inner_sum += 1./2. * spin_dist(Ex-Eg, jf,
                                             spin_dist_par["spincutModel"],
                                             spin_dist_par["spincutPars"]
                                             )
                    # print(spin_dist(Ex-Eg, jf))
                z[i_Ex, i_Eg] += g_pop * inner_sum
    return z


def decompose_matrix(matrix: Matrix, std: Matrix, *,
                     Eg: np.ndarray, nld: np.ndarray,
                     Ex: np.ndarray, resolution: np.ndarray,
                     p0=None,
                     method="Powell", options={'disp': True},
                     fill_value=0,
                     use_z=False,
                     spin_dist_par=None):
    """ Decompose first generation matrix into nld and transmission coefficient

    Parameters:
    -----------
    matrix : ndarray
        First generations matrix to be decomposed
    Eg, nld, Ex : ndarray
        Array of middle-bin values for Eg, nld and Ex
    method : str
        minimization method
    options : dict
        minimization methods
    fill_value : currently unused
    p0 (np.ndarray, optional):
        Initial guess for nld and transmission coefficient. See `FitRhoT.fit()`
    use_z (bool or np.ndarray, optional):
        See `FitRhoT.fit`; if not `False`, the created z-factor array
        will be returned.
    spin_dist_par (dict, optional):
        Dict of spin-parity paramters to create the `z-factor`, see
        See `FitRhoT.fit`

    Returns:
    --------
    rho_fit: ndarray
        fitted nld
    T_fit: ndarray
        fitted transmission coefficient
    z_array (optional): If `use_z` is not `False`, the array for the
                        `z-factor`is returned, too

    """
    # protect input arrays
    values = np.copy(matrix.values)
    std = np.copy(std.values)

    Nbins_Ex, Nbins_T = np.shape(matrix)
    Nbins_rho = Nbins_T

    values, std = normalize(values, std)

    # Addition 20190329 to add z factor:
    z_array = None
    if use_z is False:
        z_array = np.ones((Nbins_Ex, Nbins_T))
    elif use_z is True:
        z_array = z_from_spin_dist(Ex, Eg,
                                   spin_dist_par=spin_dist_par)
    else:
        z_array = use_z

    assert z_array is not None, "z_array should be set"

    # initial guesses
    rho0 = np.ones(Nbins_T)

    if p0 is None:
        T0 = values.sum(axis=0)
        p0 = np.append(rho0, T0)

    # minimization
    res = minimize(objfun1D, x0=p0,
                   args=(matrix, std,
                         Eg, nld, Ex, resolution, z_array),
                   method=method,
                   options=options)
    p_fit = res.x

    rho_fit, T_fit = rhoTfrom1D(p_fit, Nbins_rho)

    if use_z is False:
        return rho_fit, T_fit
    else:
        return rho_fit, T_fit, z_array

def normalize(values, std=0):
    matrix = unumpy.uarray(values, std)

    # normalize each Ex row to 1 (-> get decay probability)
    for i, total in enumerate(matrix.sum(axis=1)):
        matrix[i, :] = div0(matrix[i, :], total)
    values = unumpy.nominal_values(matrix)
    std = unumpy.std_devs(matrix)

    return values, std

def decompose_matrix_with_unc(P_in, P_err, Emid_Eg, Emid_nld, Emid_Ex, N_mc, method="Powell", options={'disp': True}, fill_value=0):
    """
    Routine for the decomposition of the first generations spectrum P_in
    including a simple seach for statistical uncertainties. Perturbes input spectrum N_mc times and finds the mean and stddev. of the resulting fits.


    Parameters:
    -----------
    P_in : ndarray
        First generations matrix to be decomposed
    Emin : ndarray
        Array of middle-bin values
    Emid_Eg, Emid_nld, Emid_Ex : ndarray
        Array of middle-bin values for Eg, nld and Ex
    dE_resolution : nparray
        Detector resolution
    N_mc : int
        Number of iterations for the perturbation
    method : str
        minimization method
    options : dict
        minimization methods
    fill_value : currently unused

    Returns:
    --------
    rho_fit: ndarray
        fitted nld (2D: mean, std)
    T_fit: ndarray
        fitted transmission coefficient (2D: mean, std)
    """
    P_in=np.copy(P_in)

    Nbins_Ex, Nbins_T = np.shape(P_in)
    Nbins_rho = Nbins_T
    rhos = np.zeros((N_mc,Nbins_rho))
    Ts = np.zeros((N_mc,Nbins_T))

    for i_mc in range(N_mc):
        P_in_mc = np.random.poisson(np.where(P_in>0, P_in, 0))
        rhos[i_mc,:], Ts[i_mc,:] = decompose_matrix(P_in_mc, P_err, Emid_Eg,
                                  Emid_nld, Emid_Ex,
                                  method=method,
                                  options=options,
                                  fill_value=fill_value)

    rho_fit = rhos.mean(axis=0)
    rho_fit_err = rhos.std(axis=0)
    rho_fit = np.c_[rho_fit,rho_fit_err]

    T_fit = Ts.mean(axis=0)
    T_fit_err = Ts.std(axis=0)
    T_fit = np.c_[T_fit,T_fit_err]

    return rho_fit, T_fit


def objfun1D(x, *args):
    """
    1D version of the chi2 function (needed for minimize function)
    so x has one dimension only, but may be nested to contain rho and T

    Parameters:
    ----------
    x: ndarray
        workaround: 1D representation of the parameters rho and T
    args: tuple
        tuple of the fixed parameters needed to completely specify the function

    """

    Pexp, Perr, Emid_Eg, Emid_nld, Emid_Ex, dE_resolution, z_array = args
    Pexp = np.asarray(Pexp)
    Perr = np.asarray(Perr)
    Emid_Eg = np.asarray(Emid_Eg)
    Emid_nld = np.asarray(Emid_nld)
    Emid_Ex = np.asarray(Emid_Ex)
    dE_resolution = np.asarray(dE_resolution)
    z_array = np.asarray(z_array)
    Pexp = Pexp.reshape(-1, Pexp.shape[-1])
    Nbins_Ex, Nbins_T = np.shape(Pexp)
    Nbins_rho = Nbins_T
    rho, T = rhoTfrom1D(x, Nbins_rho)
    return chi2(rho, T, Pexp, Perr, Emid_Eg, Emid_nld, Emid_Ex, dE_resolution,
                z_array)


def chi2(np.ndarray rho, np.ndarray T, np.ndarray Pexp, np.ndarray Perr,
         np.ndarray Emid_Eg, np.ndarray Emid_nld, np.ndarray Emid_Ex,
         np.ndarray dE_resolution, np.ndarray z_array):
    """ Chi^2 between experimental and fitted first genration matrix"""
    cdef float chi2
    cdef np.ndarray Pfit
    if np.any(rho<0) or np.any(T<0): # hack to implement lower boundary
        chi2 = 1e20
    else:
        Nbins_Ex, Nbins_T = np.shape(Pexp)
        Pfit = PfromRhoT(rho, T, Nbins_Ex, Emid_Eg, Emid_nld, Emid_Ex,
                         dE_resolution, z_array_in=z_array)
        # chi^2 = (data - fit)^2 / unc.^2, where unc.^2 = #cnt for Poisson dist.
        chi2 = np.sum( div0((Pexp - Pfit)**2,Perr**2))
    return chi2


@cython.boundscheck(True) # turn off bounds-checking for entire function
@cython.wraparound(True)  # turn off negative index wrapping for entire function
def PfromRhoT(np.ndarray rho, np.ndarray T, int Nbins_Ex, np.ndarray Emid_Eg,
              np.ndarray Emid_nld, np.ndarray Emid_Ex,
              np.ndarray dE_resolution, type="transCoeff",
              np.ndarray z_array_in=None):
    """ Generate a first gernation matrix P from given nld and T (or gsf)
    Parameters:
    -----------
    rho: ndarray
        nld
    T: ndarray, optional
        transmission coefficient; either this or gsf must be specified
    gsf: ndarray, optional
        gamma-ray strength function; either this or gsf must be specified
    type: string, optional
        chosen by type= "transCoeff" /or/ "gsfL1"
    Nbins_Ex, Emid_Eg, Emid_nld, Emid_Ex, dE_resolution:
        bin number and bin center values
    Note: rho and T must have the same bin width
    Returns:
    --------
    P: ndarray
        normalized first generations matrix (sum of each Ex bin = 1)
    """

    cdef int Nbins_T = len(T)
    cdef int i_Ex, i_Eg, i_Ef, Nbins
    cdef double Ef, Ex
    cdef double Eg
    cdef np.ndarray z_array
    if z_array_in is None:
        # Don't use any z factor:
        raise Exception("Something is wrong with the z array logic. This is hacky code.")
    else:
        z_array = z_array_in

    global Emid_Eg
    cdef np.ndarray P = np.zeros((Nbins_Ex,Nbins_T))

    for i_Ex in range(Nbins_Ex):
        Ex = Emid_Ex[i_Ex]
        Eg_max = Ex + dE_resolution[i_Ex]
        Nbins = (np.abs(Emid_Eg - Eg_max)).argmin() + 1
        for i_Eg in range(Nbins):
            Ef = Emid_Ex[i_Ex] - Emid_Eg[i_Eg]
            i_Ef = (np.abs(Emid_nld-Ef)).argmin()
            P[i_Ex, i_Eg] = rho[i_Ef] * T[i_Eg] * z_array[i_Ex, i_Eg]
            # if input T was a gsf, not transmission coeff: * E^(2L+1)
            if type == "gsfL1":
                Eg = Emid_Eg[i_Eg]
                P[i_Ex, i_Eg] *= np.power(Eg,3.)
    # normalize each Ex row to 1 (-> get decay probability)
    for i, normalization in enumerate(np.sum(P, axis=1)):
        P[i, :] /= normalization
    return P



def div0(np.ndarray a, np.ndarray b ):
    """ division function designed to ignore / 0,
    i.e. div0( [-1, 0, 1], 0 ) -> [0, 0, 0] """
    cdef np.ndarray c
    with np.errstate(divide='ignore', invalid='ignore'):
        c = np.true_divide( a, b )
        c[ ~ np.isfinite( c )] = 0  # -inf inf NaN
    return c


def rhoTfrom1D(np.ndarray x1D, int Nbins_rho):
    """ split 1D array to who equal length subarrays """
    cdef np.ndarray rho = x1D[:Nbins_rho]
    cdef np.ndarray T = x1D[Nbins_rho:]
    return rho, T


def fg_cut_matrix(array, Emid, Egmin, Exmin, Emax, **kwargs):
    """ Make the first generation cuts to the matrix
    Parameters:
    -----------
    array : ndarray
        2D Array that will be sliced
    Emid : ndarray
        Array of bin center energies [Note: up to here assumed symetrix for
        both axes]
    Egmin, Exmin, Emax : doubles
        Lower and higher cuts for the gamma-ray and excitation energy axis
    kwargs: optional
        Will be ignored, just for compatibility;
    Returns:
    --------
    array : ndarray
        Sliced array
    Emid_Eg : ndarray
        Bin center energies of the gamma-ray axis
    Emid_Ex : ndarray
        Bin center energies of the excitation energy axis
    Emid_nld : ndarray
        Bin center energies of the nld once extracted
    """

    np.copy(array)

    # Eg
    i_Egmin = (np.abs(Emid-Egmin)).argmin()
    i_Emax = (np.abs(Emid-Emax)).argmin()+1
    # Ex
    i_Exmin = (np.abs(Emid-Exmin)).argmin()

    array = array[i_Exmin:i_Emax,i_Egmin:i_Emax]
    Emid_Ex = Emid[i_Exmin:i_Emax]
    Emid_Eg = Emid[i_Egmin:i_Emax]
    Emid_nld = Emid[:i_Emax-i_Egmin]

    return array, Emid_Eg, Emid_Ex, Emid_nld

def spin_dist(Ex, J, spincutModel, spincutPars):
    """ See `SpinFunctions` """
    return SpinFunctions(Ex=Ex, J=J,
                         model=spincutModel,
                         pars=spincutPars).distibution()


def z_from_spin_dist(np.ndarray Exarr, np.ndarray Egarr, spin_dist_par=None):
    """
    Create a array for the *z-factor*, a spin-parity dependent factor
    that *might* have be missing the in previous implementation of the
    Oslo Method.
    """
    cdef np.ndarray z
    cdef float inner_sum
    cdef list Jfs
    cdef float g_pop
    cdef int ji
    cdef int jf
    cdef int i_Ex, i_Eg
    cdef float Ex, Eg

    # If no spin distribution parameters are specified, use some defaults:
    # (TODO: This could be made nicer, but let's get some use experience first)
    if spin_dist_par is None:
        spin_dist_par = {
            # some dummy values:
            "spincutModel": "EB05",
            "spincutPars": {"mass": 164, "NLDa": 25.16, "Eshift": 0.12},
            "Jmax": 20
        }

    cdef np.ndarray Js = np.linspace(0, spin_dist_par["Jmax"],
                                     spin_dist_par["Jmax"]+1)

    z = np.zeros((len(Exarr), len(Egarr)))

    for i_Ex, Ex in enumerate(Exarr):
        for i_Eg, Eg in enumerate(Egarr):
            if Ex-Eg <= 0:
                continue
            for ji in Js:
                if ji==0:
                    Jfs = [1]
                else:
                    Jfs = [ji-1, ji, ji+1]
                # assume g_pop propto g_int
                # TODO: should the 1/2 be there?
                g_pop = 1./2. * spin_dist(Ex, ji,
                                          spin_dist_par["spincutModel"],
                                          spin_dist_par["spincutPars"]
                                          )
                inner_sum = 0
                for jf in Jfs:
                    # TODO: should the 1/2 be there?
                    inner_sum += 1./2. * spin_dist(Ex-Eg, jf,
                                             spin_dist_par["spincutModel"],
                                             spin_dist_par["spincutPars"]
                                             )
                    # print(spin_dist(Ex-Eg, jf))
                z[i_Ex, i_Eg] += g_pop * inner_sum
    return z
