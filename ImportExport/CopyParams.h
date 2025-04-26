/*
 * Copyright 2022 HEAVY.AI, Inc.
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

/*
 * @file CopyParams.h
 * @brief CopyParams struct
 *
 */

#pragma once

#include <optional>
#include <string>

#include "ImportExport/SourceType.h"
#include "Shared/sqltypes.h"

namespace import_export {

// not too big (need much memory) but not too small (many thread forks)
constexpr static size_t kImportFileBufferSize = (1 << 23);

// import buffers may grow to this size if necessary
constexpr static size_t max_import_buffer_resize_byte_size = 1024 * 1024 * 1024;

enum class ImportHeaderRow { kAutoDetect, kNoHeader, kHasHeader };
enum class RasterPointType { kNone, kAuto, kSmallInt, kInt, kFloat, kDouble, kPoint };
enum class RasterPointTransform { kNone, kAuto, kFile, kWorld };

struct CopyParams {
  char delimiter;
  std::string null_str;
  ImportHeaderRow has_header;
  bool quoted;  // does the input have any quoted fields, default to false
  char quote;
  char escape;
  char line_delim;
  std::string array_delim;
  char array_begin;
  char array_end;
  int threads;
  size_t
      max_reject;  // maximum number of records that can be rejected before copy is failed
  import_export::SourceType source_type;
  bool plain_text = false;
  bool trim_spaces;
  // s3/parquet related params
  std::string s3_access_key;  // per-query credentials to override the
  std::string s3_secret_key;  // settings in ~/.aws/credentials or environment
  std::string s3_session_token = "";
  std::string s3_region;
  std::string s3_endpoint;
  int32_t s3_max_concurrent_downloads =
      8;  // maximum number of concurrent file downloads from S3
  // kafka related params
  size_t retry_count;
  size_t retry_wait;
  size_t batch_size;
  size_t buffer_size;
  size_t max_import_batch_row_count;
  // geospatial params
  bool lonlat;
  EncodingType geo_coords_encoding;
  int32_t geo_coords_comp_param;
  SQLTypes geo_coords_type;
  int32_t geo_coords_srid;
  bool sanitize_column_names;
  std::string geo_layer_name;
  bool geo_explode_collections;
  bool geo_validate_geometry;
  int32_t source_srid;
  std::optional<std::string> regex_path_filter;
  std::optional<std::string> file_sort_order_by;
  std::optional<std::string> file_sort_regex;
  RasterPointType raster_point_type;
  std::string raster_import_bands;
  int32_t raster_scanlines_per_thread;
  RasterPointTransform raster_point_transform;
  bool raster_point_compute_angle;
  std::string raster_import_dimensions;
  std::string add_metadata_columns;
  bool raster_drop_if_all_null;
  // odbc parameters
  std::string sql_select;
  std::string sql_order_by;
  // odbc user mapping parameters
  std::string username;
  std::string password;
  std::string credential_string;
  // odbc server parameters
  std::string dsn;
  std::string connection_string;
  // regex parameters
  std::string line_start_regex;
  std::string line_regex;

  CopyParams()
      : delimiter(',')
      , null_str("\\N")
      , has_header(ImportHeaderRow::kAutoDetect)
      , quoted(true)
      , quote('"')
      , escape('"')
      , line_delim('\n')
      , array_delim(",")
      , array_begin('{')
      , array_end('}')
      , threads(0)
      , max_reject(100000)
      , source_type(import_export::SourceType::kDelimitedFile)
      , trim_spaces(true)
      , retry_count(100)
      , retry_wait(5)
      , batch_size(1000)
      , buffer_size(kImportFileBufferSize)
      , max_import_batch_row_count(0)
      , lonlat(true)
      , geo_coords_encoding(kENCODING_GEOINT)
      , geo_coords_comp_param(32)
      , geo_coords_type(kGEOMETRY)
      , geo_coords_srid(4326)
      , sanitize_column_names(true)
      , geo_explode_collections(false)
      , geo_validate_geometry{false}
      , source_srid(0)
      , raster_point_type(RasterPointType::kAuto)
      , raster_scanlines_per_thread(32)
      , raster_point_transform(RasterPointTransform::kAuto)
      , raster_point_compute_angle{false}
      , raster_drop_if_all_null{false} {}

  CopyParams(char d, const std::string& n, char l, size_t b, size_t retries, size_t wait)
      : delimiter(d)
      , null_str(n)
      , has_header(ImportHeaderRow::kAutoDetect)
      , quoted(true)
      , quote('"')
      , escape('"')
      , line_delim(l)
      , array_delim(",")
      , array_begin('{')
      , array_end('}')
      , threads(0)
      , max_reject(100000)
      , source_type(import_export::SourceType::kDelimitedFile)
      , trim_spaces(true)
      , retry_count(retries)
      , retry_wait(wait)
      , batch_size(b)
      , buffer_size(kImportFileBufferSize)
      , max_import_batch_row_count(0)
      , lonlat(true)
      , geo_coords_encoding(kENCODING_GEOINT)
      , geo_coords_comp_param(32)
      , geo_coords_type(kGEOMETRY)
      , geo_coords_srid(4326)
      , sanitize_column_names(true)
      , geo_explode_collections(false)
      , geo_validate_geometry{false}
      , source_srid(0)
      , raster_point_type(RasterPointType::kAuto)
      , raster_scanlines_per_thread(32)
      , raster_point_transform(RasterPointTransform::kAuto)
      , raster_point_compute_angle{false}
      , raster_drop_if_all_null{false} {}

      CopyParams(const CopyParams& other)
    : delimiter(other.delimiter)
    , null_str(other.null_str)
    , has_header(other.has_header)
    , quoted(other.quoted)
    , quote(other.quote)
    , escape(other.escape)
    , line_delim(other.line_delim)
    , array_delim(other.array_delim)
    , array_begin(other.array_begin)
    , array_end(other.array_end)
    , threads(other.threads)
    , max_reject(other.max_reject)
    , source_type(other.source_type)
    , plain_text(other.plain_text)
    , trim_spaces(other.trim_spaces)
    , s3_access_key(other.s3_access_key)
    , s3_secret_key(other.s3_secret_key)
    , s3_session_token(other.s3_session_token)
    , s3_region(other.s3_region)
    , s3_endpoint(other.s3_endpoint)
    , s3_max_concurrent_downloads(other.s3_max_concurrent_downloads)
    , retry_count(other.retry_count)
    , retry_wait(other.retry_wait)
    , batch_size(other.batch_size)
    , buffer_size(other.buffer_size)
    , max_import_batch_row_count(other.max_import_batch_row_count)
    , lonlat(other.lonlat)
    , geo_coords_encoding(other.geo_coords_encoding)
    , geo_coords_comp_param(other.geo_coords_comp_param)
    , geo_coords_type(other.geo_coords_type)
    , geo_coords_srid(other.geo_coords_srid)
    , sanitize_column_names(other.sanitize_column_names)
    , geo_layer_name(other.geo_layer_name)
    , geo_explode_collections(other.geo_explode_collections)
    , geo_validate_geometry(other.geo_validate_geometry)
    , source_srid(other.source_srid)
    , regex_path_filter(other.regex_path_filter)
    , file_sort_order_by(other.file_sort_order_by)
    , file_sort_regex(other.file_sort_regex)
    , raster_point_type(other.raster_point_type)
    , raster_import_bands(other.raster_import_bands)
    , raster_scanlines_per_thread(other.raster_scanlines_per_thread)
    , raster_point_transform(other.raster_point_transform)
    , raster_point_compute_angle(other.raster_point_compute_angle)
    , raster_import_dimensions(other.raster_import_dimensions)
    , add_metadata_columns(other.add_metadata_columns)
    , raster_drop_if_all_null(other.raster_drop_if_all_null)
    , sql_select(other.sql_select)
    , sql_order_by(other.sql_order_by)
    , username(other.username)
    , password(other.password)
    , credential_string(other.credential_string)
    , dsn(other.dsn)
    , connection_string(other.connection_string)
    , line_start_regex(other.line_start_regex)
    , line_regex(other.line_regex) {}
};

}  // namespace import_export
