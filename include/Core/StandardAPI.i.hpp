/**
 * @author Federico Busato                                                  <br>
 *         Univerity of Verona, Dept. of Computer Science                   <br>
 *         federico.busato@univr.it
 * @date August, 2017
 * @version v2
 *
 * @copyright Copyright © 2017 Hornet. All rights reserved.
 *
 * @license{<blockquote>
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * * Neither the name of the copyright holder nor the names of its
 *   contributors may be used to endorse or promote products derived from
 *   this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 * </blockquote>}
 *
 */
#pragma once

#include <Device/Algorithm.cuh>
#include "Device/SafeCudaAPI.cuh"
#include "Device/CubWrapper.cuh"
#include <omp.h>
#include <cstring>

namespace hornet {
namespace gpu {

template<typename T>
void allocate(T*& pointer, size_t num_items) {
    cuMalloc(pointer, num_items);
}

template<typename T>
void free(T* pointer) {
    cuFree(pointer);
}

template<typename T>
void copyToDevice(const T* device_input, size_t num_items, T* device_output) {
    cuMemcpyDeviceToDevice(device_input, num_items, device_output);
}

template<typename T>
void copyToHost(const T* device_input, size_t num_items, T* host_output) {
    cuMemcpyToHost(device_input, num_items, host_output);
}

template<typename T>
void copyFromHost(const T* host_input, size_t num_items, T* device_output) {
    cuMemcpyToDevice(host_input, num_items, device_output);
}
/*
template<typename T>
void copyHostToDevice(T value, T* destination) {
    cuMemcpyToDevice(value, destination);
}

template<typename T>
void copyDeviceToHost(const T* source, size_t num_items, T* destination) {
    cuMemcpyToHost(source, num_items, destination);
}

template<typename T>
void copyDeviceToHost(const T* source, T& value) {
    cuMemcpyToHost(source, value);
}*/

template<typename T>
void memsetZero(T* pointer, size_t num_items) {
    cuMemset0x00(pointer, num_items);
}

template<typename T>
void memsetOne(T* pointer, size_t num_items) {
    cuMemset0xFF(pointer, num_items);
}

template<typename T>
T reduce(const T* input, size_t num_items) {
    xlib::CubReduce<T> cub_reduce(input, num_items);
    return cub_reduce.run();
}

template<typename T>
void excl_prefixsum(const T* input, size_t num_items, T* output) {
    xlib::CubExclusiveSum<T> cub_prefixsum(input, num_items, output);
    cub_prefixsum.run();
}

template<typename HostIterator, typename DeviceIterator>
bool equal(HostIterator host_start, HostIterator host_end,
           DeviceIterator device_start) noexcept {
    return cu::equal(host_start, host_end, device_start);
}

template<typename T>
void print(const T* device_input, size_t num_items) {
    cu::printArray(device_input, num_items);
}

} // namespace gpu

//==============================================================================

namespace host {

template<typename T>
void allocate(T*& pointer, size_t num_items) {
    pointer = new T[num_items];
}

template<typename T>
void free(T*& pointer) {
    delete[] pointer;
}

template<typename T>
void copyToHost(const T* host_input, size_t num_items, T* host_output) {
    std::copy(host_input, host_input + num_items, host_output);
}

template<typename T>
void copyToDevice(const T* host_input, size_t num_items, T* device_output) {
    cuMemcpyToDevice(host_input, num_items, device_output);
}

template<typename T>
void copyToDevice(T host_value, T* device_output) {
    cuMemcpyToDevice(host_value, device_output);
}

template<typename T>
void copyFromDevice(const T* device_input, size_t num_items, T* host_output) {
    cuMemcpyToHost(device_input, num_items, host_output);
}

template<typename T>
void copyFromDevice(const T* device_input, T& host_output) {
    cuMemcpyToHost(device_input, host_output);
}

template<typename T>
void memsetZero(T* pointer, size_t num_items) {
    std::memset(pointer, 0x0, num_items * sizeof(T));
}

template<typename T>
void memsetOne(T* pointer, size_t num_items) {
    std::memset(pointer, 0xFF, num_items * sizeof(T));
}

template<typename T>
T reduce(const T* input, size_t num_items) {
    T th_result[MAX_THREADS];
    #pragma omp parallel firstprivate(input, num_items)
    {
        T result;
        #pragma omp for schedule(static) nowait
        for (int i = 0; i < num_items; i++)
            result += input[i];
        th_result[omp_get_thread_num()] = result;
    }
    return std::accumulate(input, input + omp_get_num_threads(), T(0));
}

template<typename T>
void excl_prefixsum(const T* input, size_t num_items, T* output) {
    T th_result[MAX_THREADS];
    #pragma omp parallel firstprivate(input, num_items, th_result)
    {
        T result;
        #pragma omp for schedule(static) nowait
        for (int i = 0; i < num_items; i++)
            result += input[i];
        th_result[omp_get_thread_num() + 1] = result;
    }
    th_result[omp_get_thread_num()] = 0;
    std::partial_sum(input, input + omp_get_num_threads() + 1);
    output[0] = 0;

    #pragma omp parallel firstprivate(input, num_items, th_result)
    {
        T partial = th_result[omp_get_thread_num()];
        bool flag = true;
        #pragma omp for schedule(static) nowait
        for (int i = 0; i < num_items; i++) {
            output[i] = flag ? partial : input[i - 1] + output[i - 1] + partial;
            flag = false;
        }
    }
}

template<typename T>
void print(const T* host_input, size_t num_items) {
    xlib::printArray(host_input, num_items);
}

} // namespace host
} // namespace hornet
