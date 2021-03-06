/**
 * @author Federico Busato                                                  <br>
 *         Univerity of Verona, Dept. of Computer Science                   <br>
 *         federico.busato@univr.it
 * @date September, 2017
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
 */

#include "Static/BreadthFirstSearch/TopDown.cuh"
#include "Core/Auxilary/DuplicateRemoving.cuh"
#include <GraphIO/GraphStd.hpp>
#include <GraphIO/BFS.hpp>

namespace hornet_alg {

const dist_t INF = std::numeric_limits<dist_t>::max();

//------------------------------------------------------------------------------
///////////////
// OPERATORS //
///////////////

struct BFSOperator {
    dist_t*              d_distances;
    dist_t               current_level;
    TwoLevelQueue<vid_t> queue;

    OPERATOR(Vertex& vertex, Edge& edge) {
        auto dst = edge.dst_id();
        if (d_distances[dst] == INF) {//!is_duplicate<2>(dst) &&
            d_distances[dst] = current_level;
            queue.insert(dst);
        }
    }
};
//------------------------------------------------------------------------------
/////////////////
// BfsTopDown //
/////////////////

BfsTopDown::BfsTopDown(HornetGPU& hornet) :
                                 StaticAlgorithm(hornet),
                                 queue(hornet),
                                 load_balacing(hornet) {
    gpu::allocate(d_distances, hornet.nV());
    reset();
}

BfsTopDown::~BfsTopDown() {
    gpu::free(d_distances);
}

void BfsTopDown::reset() {
    current_level = 1;
    queue.clear();

    auto distances = d_distances;
    forAllnumV(hornet, [=] __device__ (int i){ distances[i] = INF; } );
}

void BfsTopDown::set_parameters(vid_t source) {
    bfs_source = source;
    queue.insert(bfs_source);               // insert bfs source in the frontier
    gpu::memsetZero(d_distances + bfs_source);  //reset source distance
}

void BfsTopDown::run() {
    while (queue.size() > 0) {
        //std::cout << queue.size() << std::endl;
        //for all edges in "queue" applies the operator "BFSOperator" by using
        //the load balancing algorithm instantiated in "load_balacing"
        forAllEdges(hornet, queue,
                    BFSOperator { d_distances, current_level, queue },
                    load_balacing);
        current_level++;
        queue.swap();
    }
}

//same procedure of run() but it uses lambda expression instead explict
//struct operator
void BfsTopDown::run2() {
    auto distances = d_distances;
    auto     level = 1;

    while (queue.size() > 0) {
        auto queue1 = queue;
        const auto& BFSLambda = [=] __device__(auto vertex, auto edge) mutable {
                                    auto dst = edge.dst_id();
                                    if (distances[dst] == INF) {
                                        distances[dst] = level;
                                        queue1.insert(dst);
                                    }
                                };

        forAllEdges(hornet, queue, BFSLambda, load_balacing);
        level++;
        queue.swap();
    }
}

void BfsTopDown::release() {
    gpu::free(d_distances);
    d_distances = nullptr;
}

bool BfsTopDown::validate() {
    std::cout << "\nTotal enqueue vertices: "
              << xlib::format(queue.enqueue_items())
              << std::endl;

    using namespace graph;
    GraphStd<vid_t, eoff_t> graph(hornet.csr_offsets(), hornet.nV(),
                                  hornet.csr_edges(), hornet.nE());
    BFS<vid_t, eoff_t> bfs(graph);
    bfs.run(bfs_source);

    auto h_distances = bfs.result();
    return gpu::equal(h_distances, h_distances + graph.nV(), d_distances);
}

} // namespace hornet_alg
