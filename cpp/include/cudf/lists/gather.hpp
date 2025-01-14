/*
 * Copyright (c) 2021-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/copying.hpp>
#include <cudf/lists/lists_column_view.hpp>

#include <rmm/mr/device/per_device_resource.hpp>

namespace cudf {
namespace lists {
/**
 * @addtogroup lists_gather
 * @{
 * @file
 */

/**
 * @brief Segmented gather of the elements within a list element in each row of a list column.
 *
 * `source_column` with any depth and `gather_map_list` with depth 1 are only supported.
 *
 * @code{.pseudo}
 * source_column   : [{"a", "b", "c", "d"}, {"1", "2", "3", "4"}, {"x", "y", "z"}]
 * gather_map_list : [{0, 1, 3, 2}, {1, 3, 2}, {}]
 *
 * result          : [{"a", "b", "d", "c"}, {"2", "4", "3"}, {}]
 * @endcode
 *
 * @throws cudf::logic_error if `gather_map_list` size is not same as `source_column` size.
 * @throws std::invalid_argument if gather_map contains null values.
 * @throws cudf::logic_error if gather_map is not list column of an index type.
 *
 * If indices in `gather_map_list` are outside the range `[-n, n)`, where `n` is the number of
 * elements in corresponding row of the source column, the behavior is as follows:
 *   1. If `bounds_policy` is set to `DONT_CHECK`, the behavior is undefined.
 *   2. If `bounds_policy` is set to `NULLIFY`, the corresponding element in the list row
 *      is set to null in the output column.
 *
 * @code{.pseudo}
 * source_column       : [{"a", "b", "c", "d"}, {"1", "2", "3", "4"}, {"x", "y", "z"}]
 * gather_map_list     : [{0, -1, 4, -5}, {1, 3, 5}, {}]
 *
 * result_with_nullify : [{"a", "d", null, null}, {"2", "4", null}, {}]
 * @endcode
 *
 * @param source_column View into the list column to gather from
 * @param gather_map_list View into a non-nullable list column of integral indices that maps the
 * element in list of each row in the source columns to rows of lists in the destination columns.
 * @param bounds_policy Can be `DONT_CHECK` or `NULLIFY`. Selects whether or not to nullify the
 * output list row's element, when the gather index falls outside the range `[-n, n)`,
 * where `n` is the number of elements in list row corresponding to the gather-map row.
 * @param mr Device memory resource to allocate any returned objects
 * @return column with elements in list of rows gathered based on `gather_map_list`
 *
 */
std::unique_ptr<column> segmented_gather(
  lists_column_view const& source_column,
  lists_column_view const& gather_map_list,
  out_of_bounds_policy bounds_policy  = out_of_bounds_policy::DONT_CHECK,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/** @} */  // end of group
}  // namespace lists
}  // namespace cudf
