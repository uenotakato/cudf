/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
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

#include "stream_compaction_common.cuh"
#include "stream_compaction_common.hpp"

#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/sorting.hpp>
#include <cudf/detail/stream_compaction.hpp>
#include <cudf/stream_compaction.hpp>
#include <cudf/table/experimental/row_operators.cuh>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/count.h>
#include <thrust/execution_policy.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/logical.h>
#include <thrust/transform.h>

#include <cmath>
#include <cstddef>
#include <type_traits>
#include <utility>
#include <vector>

namespace cudf {
namespace detail {
namespace {
/**
 * @brief A functor to be used along with device type_dispatcher to check if
 * the row `index` of `column_device_view` is `NaN`.
 */
struct check_nan {
  // Check if a value is `NaN` for floating point type columns
  template <typename T, std::enable_if_t<std::is_floating_point_v<T>>* = nullptr>
  __device__ inline bool operator()(column_device_view const& input, size_type index)
  {
    return std::isnan(input.data<T>()[index]);
  }
  // Non-floating point type columns can never have `NaN`, so it will always return false.
  template <typename T, std::enable_if_t<not std::is_floating_point_v<T>>* = nullptr>
  __device__ inline bool operator()(column_device_view const&, size_type)
  {
    return false;
  }
};
}  // namespace

cudf::size_type unique_count(table_view const& keys,
                             null_equality nulls_equal,
                             rmm::cuda_stream_view stream)
{
  auto const row_comp = cudf::experimental::row::equality::self_comparator(keys, stream);
  if (cudf::detail::has_nested_columns(keys)) {
    auto const comp =
      row_comp.equal_to<true>(nullate::DYNAMIC{has_nested_nulls(keys)}, nulls_equal);
    // Using a temporary buffer for intermediate transform results from the lambda containing
    // the comparator speeds up compile-time significantly without much degradation in
    // runtime performance over using the comparator directly in thrust::count_if.
    auto d_results = rmm::device_uvector<bool>(keys.num_rows(), stream);
    thrust::transform(rmm::exec_policy(stream),
                      thrust::make_counting_iterator<size_type>(0),
                      thrust::make_counting_iterator<size_type>(keys.num_rows()),
                      d_results.begin(),
                      [comp] __device__(auto i) { return (i == 0 or not comp(i, i - 1)); });

    return static_cast<size_type>(
      thrust::count(rmm::exec_policy(stream), d_results.begin(), d_results.end(), true));
  } else {
    auto const comp =
      row_comp.equal_to<false>(nullate::DYNAMIC{has_nested_nulls(keys)}, nulls_equal);
    // Using thrust::copy_if with the comparator directly will compile more slowly but
    // improves runtime by up to 2x over the transform/count approach above.
    return thrust::count_if(
      rmm::exec_policy(stream),
      thrust::counting_iterator<cudf::size_type>(0),
      thrust::counting_iterator<cudf::size_type>(keys.num_rows()),
      [comp] __device__(cudf::size_type i) { return (i == 0 or not comp(i, i - 1)); });
  }
}

cudf::size_type unique_count(column_view const& input,
                             null_policy null_handling,
                             nan_policy nan_handling,
                             rmm::cuda_stream_view stream)
{
  auto const num_rows = input.size();

  if (num_rows == 0 or num_rows == input.null_count()) { return 0; }

  auto const count_nulls      = null_handling == null_policy::INCLUDE;
  auto const nan_is_null      = nan_handling == nan_policy::NAN_IS_NULL;
  auto const should_check_nan = cudf::is_floating_point(input.type());
  auto input_device_view      = cudf::column_device_view::create(input, stream);
  auto device_view            = *input_device_view;
  auto input_table_view       = table_view{{input}};
  auto table_ptr              = cudf::table_device_view::create(input_table_view, stream);
  row_equality_comparator comp(nullate::DYNAMIC{cudf::has_nulls(input_table_view)},
                               *table_ptr,
                               *table_ptr,
                               null_equality::EQUAL);

  return thrust::count_if(
    rmm::exec_policy(stream),
    thrust::counting_iterator<cudf::size_type>(0),
    thrust::counting_iterator<cudf::size_type>(num_rows),
    [count_nulls, nan_is_null, should_check_nan, device_view, comp] __device__(cudf::size_type i) {
      auto const is_null = device_view.is_null(i);
      auto const is_nan  = nan_is_null and should_check_nan and
                          cudf::type_dispatcher(device_view.type(), check_nan{}, device_view, i);
      if (not count_nulls and (is_null or (nan_is_null and is_nan))) { return false; }
      if (i == 0) { return true; }
      if (count_nulls and nan_is_null and (is_nan or is_null)) {
        auto const prev_is_nan =
          should_check_nan and
          cudf::type_dispatcher(device_view.type(), check_nan{}, device_view, i - 1);
        return not(prev_is_nan or device_view.is_null(i - 1));
      }
      return not comp(i, i - 1);
    });
}
}  // namespace detail

cudf::size_type unique_count(column_view const& input,
                             null_policy null_handling,
                             nan_policy nan_handling)
{
  CUDF_FUNC_RANGE();
  return detail::unique_count(input, null_handling, nan_handling, cudf::get_default_stream());
}

cudf::size_type unique_count(table_view const& input, null_equality nulls_equal)
{
  CUDF_FUNC_RANGE();
  return detail::unique_count(input, nulls_equal, cudf::get_default_stream());
}

}  // namespace cudf
