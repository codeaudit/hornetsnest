/**
 * @author Federico Busato                                                  <br>
 *         Univerity of Verona, Dept. of Computer Science                   <br>
 *         federico.busato@univr.it
 * @date April, 2017
 * @version v2
 *
 * @copyright Copyright © 2017 cuStinger. All rights reserved.
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
 */
#include "Static/ConnectedComponents/CC.cuh"
#include <GraphIO/WCC.hpp>

namespace hornet_alg {

const color_t    NO_COLOR = std::numeric_limits<color_t>::max();
const color_t FIRST_COLOR = color_t(0);
//------------------------------------------------------------------------------
///////////////
// OPERATORS //
///////////////

struct GiantCCOperator {
    color_t*             d_colors;
    TwoLevelQueue<vid_t> queue;

    OPERATOR(Vertex& src, Edge& edge) {
        auto dst = edge.dst_id();
        if (d_colors[dst] == NO_COLOR) {
            d_colors[dst] = FIRST_COLOR;
            queue.insert(dst);
        }
    }
};

struct BuildVertexEnqueue {
    color_t*             d_colors;
    TwoLevelQueue<vid_t> queue;

    OPERATOR(Vertex& src) {
        if (d_colors[src.id()] == NO_COLOR)
            queue.insert(src.id());
    }
};

struct BuildPairQueue {
    TwoLevelQueue<idpair_t> queue;

    OPERATOR(Vertex& src, Edge& edge) {
        if (src.id() > edge.dst_id())
            queue.insert({ src.id(), edge.dst_id() });
    }
};

struct ColoringOperator {
    color_t*            d_colors;
    HostDeviceVar<bool> d_continue;

    OPERATOR(vid2_t vertex_pair) {
        bool continue_var;
        auto src_color = d_colors[vertex_pair.x];
        auto dst_color = d_colors[vertex_pair.y];
        if (src_color > dst_color) {
            d_colors[vertex_pair.y] = d_colors[vertex_pair.x];
            continue_var = true;
        }
        else if (src_color < dst_color) {
            d_colors[vertex_pair.x] = d_colors[vertex_pair.y];
            continue_var = true;
        }
        else
            continue_var = false;

        if (continue_var)
            d_continue = true;
        //gpu::reduce_or(d_continue.ptr(), continue_var);
    }
};

/*
struct ColorigAtomic {
    EnqueueOperator(color_t* d_colors_, TwoLevelQueue<int2> queue_) :
                                Common(d_colors_, queue_) {}

    __device__ __forceinline__
    bool operator()(const int2& item) {
        auto src_color = d_colors[item.x];
        auto old_color = atomicMax(d_colors + item.y, src_color);
        if (src_color < old_color)
            atomicMax(d_colors + item.x, old_color);
        //d_colors[item.x] = old_color;
    }
};*/

//------------------------------------------------------------------------------
////////
// CC //
////////

CC::CC(HornetGPU& hornet) : StaticAlgorithm(hornet),
                            queue(hornet),
                            queue_pair(hornet),
                            load_balacing(hornet) {
    gpu::allocate(d_colors, hornet.nV());
    reset();
}

CC::~CC() {
    gpu::free(d_colors);
}

void CC::reset() {
    queue.clear();

    auto colors = d_colors;
    forAllnumV(hornet, [=] __device__ (int i){ colors[i] = NO_COLOR; } );
}

void CC::run() {
    auto max_vertex = hornet.max_degree_id();
    queue.insert(max_vertex);

    while (queue.size() > 0) {
        forAllEdges(hornet, queue, GiantCCOperator { d_colors, queue },
                    load_balacing);
        queue.swap();
    }

    queue.clear();
    forAllVertices(hornet, BuildVertexEnqueue { d_colors, queue });

    forAllEdges(hornet, queue, BuildPairQueue { queue_pair }, load_balacing);

    while (hd_continue)
        forAll(queue_pair, ColoringOperator { d_colors, hd_continue } );
}

void CC::release() {
    gpu::free(d_colors);
    d_colors = nullptr;
}

bool CC::validate() {
    using namespace graph;
    GraphStd<vid_t, eoff_t> graph(hornet.csr_offsets(), hornet.nV(),
                                  hornet.csr_edges(), hornet.nE());
    WCC<vid_t, eoff_t> wcc(graph);
    wcc.run();

    wcc.print_statistics();
    wcc.print_histogram();

    auto color_match = new color_t[ wcc.size() ];
    std::fill(color_match, color_match + wcc.size(), NO_COLOR);

    auto d_results = new color_t[graph.nV()];
    cuMemcpyToHost(d_colors, graph.nV(), d_results);
    auto h_result = wcc.result();

    for (vid_t i = 0; i < graph.nV(); i++) {
        //std::cout << h_result[i] << "\t" << d_results[i] << std::endl;
        if (color_match[ d_results[i] ] == NO_COLOR)
            color_match[ d_results[i] ] = h_result[i];
        else if (color_match[ d_results[i] ] != h_result[i])
            return false;
    }
    return true;
}

} // namespace hornet_alg