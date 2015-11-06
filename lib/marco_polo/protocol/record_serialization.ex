defmodule MarcoPolo.Protocol.RecordSerialization do
  @moduledoc false

  # This module implements the serialization/deserilization protocol described
  # here:
  # http://orientdb.com/docs/last/Record-Schemaless-Binary-Serialization.html. It's
  # a little bit of a mess.

  alias MarcoPolo.Document
  alias MarcoPolo.RID

  import MarcoPolo.Protocol.Protobuf

  require Record
  Record.defrecordp :field, [:name, :ptr, :type]

  @doc """
  Decodes a binary-serialized record into a `MarcoPolo.Record` struct.

  This function decodes the bytes representing a record into a
  `MarcoPolo.Record` struct. The record is assumed to be serialized with the
  `ORecordSerializerBinary` serialization. `data` is the full data about the
  record, it has no exceeding data and it's not incomplete. Note that `data`
  represents the bytes for the record content, without the leading int for the
  length of the byte array you would expect from OrientDB's binary
  protocol. This happens because this function is usually called from the parser
  that parsed the byte array. This also means we don't have to care about
  possibly incomplete parts of the serialized records because that would have
  been detected by the parser (that knows the size of the serialized binary).
  """
  @spec decode(binary, Dict.t) :: Document.t | :unknown_property_id
  def decode(data, schema \\ %{}) do
    <<_serialization_version, rest :: binary>> = data

    # OrientDB sometimes sends stuff after a record that they use to keep track
    # of updates and other things. Let's ignore this stuff and hope everything
    # goes fine, shall we?
    case decode_embedded(rest, schema, data) do
      {record, _cruft} ->
        record
      :unknown_property_id ->
        :unknown_property_id
    end
  end

  @doc """
  Serializes a given record using the schemaless serialization protocol.

  The record is serialized using the `ORecordSerializerBinary`
  serialization. This function always returns iodata that can be converted to
  binary using `IO.iodata_to_binary/1`.

  This function is the "dual" of `decode/2`, so this is generally true:

      decode(encode(record)) = record

  """
  @spec encode(MarcoPolo.record) :: iodata
  def encode(%Document{} = record) do
    # 0 is the serialization version (as a byte), not the record version.
    [0, encode_embedded(record, 1)]
  end

  # Decodes a document (ODocument). This ODocument can be a "top-level" document
  # or an "embedded" type, since the leading serialization version byte is not
  # decoded here (but in `decode/2`).
  defp decode_embedded(data, schema, original_data \\ nil) do
    original_data = original_data || data
    {class_name, rest} = decode_type(data, :string)

    case decode_header(rest, schema) do
      {field_definitions, _} ->
        # We're passing the whole `original_data` to the `decode_fields/3`
        # function because pointers to data will be used to retrieve the values
        # of the fields.
        {fields, rest} = decode_fields(original_data, field_definitions, schema)

        if class_name == "" do
          class_name = nil
        end

        {%Document{class: class_name, fields: fields}, rest}
      :unknown_property_id ->
        :unknown_property_id
    end
  end

  # Decodes the header of this record (which contains field definitions and
  # "pointers" to the corresponding data in the rest of the binary. Returns a
  # tuple with a list of fields as the first element and the non-header data as
  # the second element.
  defp decode_header(data, schema, acc \\ []) do
    # If `i` is positive, that means the next field definition is a "named
    # field" and `i` is the length of the field's name. If it's negative, it
    # represents the property id of a property. If it's 0, it signals the end of
    # the header segment.
    case decode_zigzag_varint(data) do
      {0, rest} ->
        {Enum.reverse(acc), rest}
      {i, rest} when i < 0 ->
        case decode_property_definition(rest, i, schema) do
          {field, rest}        -> decode_header(rest, schema, [field|acc])
          :unknown_property_id -> :unknown_property_id
        end
      {i, _} when i > 0 ->
        {field, rest} = decode_field_definition(data)
        decode_header(rest, schema, [field|acc])
    end
  end

  defp decode_property_definition(data, encoded_id, schema) do
    # That's how you decode property ids.
    id = - encoded_id - 1

    case Dict.fetch(schema.global_properties, id) do
      {:ok, {name, type_as_string}} ->
        {ptr, rest} = decode_data_ptr(data)
        field       = field(name: name, type: string_to_type(type_as_string), ptr: ptr)
        {field, rest}
      :error ->
        :unknown_property_id
    end
  end

  # Decodes the definition of a named field in the header (`data`).
  defp decode_field_definition(data) do
    {name, rest}             = decode_type(data, :string)
    {ptr, rest}              = decode_data_ptr(rest)
    <<type, rest :: binary>> = rest

    {field(name: name, type: int_to_type(type), ptr: ptr), rest}
  end

  # Here, `data` is the whole data of the embedded record because we use
  # pointers to get to the field values.
  defp decode_fields(data, field_definitions, schema) do
    fields = Enum.map(field_definitions, &decode_field(data, &1, schema))

    rest =
      case List.last(fields) do
        {_, rest} -> rest
        _         -> data
      end

    fields =
      fields
      |> Enum.map(fn {name_and_value, _rest} -> name_and_value end)
      |> Enum.into(%{})

    {fields, rest}
  end

  # A 0 pointer means the field is null.
  defp decode_field(data, field(name: name, ptr: 0), _schema) do
    {{name, nil}, data}
  end

  defp decode_field(data, field(name: name, type: type, ptr: ptr), schema) do
    pointed_data = from_pointer_to_end(data, ptr)
    {value, rest} = decode_type(pointed_data, type, schema, data)

    {{name, value}, rest}
  end

  # The pointer to the data is just a signed int32.
  defp decode_data_ptr(data) do
    <<data_ptr :: 32-signed, rest :: binary>> = data
    {data_ptr, rest}
  end

  # Decodes an instance of `type` from `data`.
  # Made public for testing.
  @doc false
  def decode_type(data, type, schema \\ HashDict.new, original_data \\ nil)

  def decode_type(<<0>> <> rest, :boolean, _, _), do: {false, rest}
  def decode_type(<<1>> <> rest, :boolean, _, _), do: {true, rest}

  def decode_type(data, type, _, _) when type in [:short, :int, :long] do
    decode_zigzag_varint(data)
  end

  def decode_type(data, :float, _, _) do
    <<float :: 32-float, rest :: binary>> = data
    {float, rest}
  end

  def decode_type(data, :double, _, _) do
    <<double :: 64-float, rest :: binary>> = data
    {double, rest}
  end

  def decode_type(data, type, _, _) when type in [:string, :binary] do
    {len, rest} = decode_zigzag_varint(data)
    <<string :: bytes-size(len), rest :: binary>> = rest
    {string, rest}
  end

  def decode_type(data, :date, _, _) do
    {days, rest} = decode_zigzag_varint(data)
    days = :calendar.date_to_gregorian_days(1970, 1, 1) + days
    {y, m, d} = :calendar.gregorian_days_to_date(days)
    {%MarcoPolo.Date{year: y, month: m, day: d}, rest}
  end

  def decode_type(data, :datetime, _, _) do
    {msecs_from_epoch, rest} = decode_type(data, :long)
    secs_from_epoch = div(msecs_from_epoch, 1000)
    msec = rem(msecs_from_epoch, 1000)
    epoch = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

    total_secs = epoch + secs_from_epoch
    {{year, month, day}, {hour, min, sec}} = :calendar.gregorian_seconds_to_datetime(total_secs)
    datetime = %MarcoPolo.DateTime{year: year, month: month, day: day,
                                   hour: hour, min: min, sec: sec, msec: msec}

    {datetime, rest}
  end

  def decode_type(data, :embedded, schema, _) do
    decode_embedded(data, schema)
  end

  def decode_type(data, :embedded_list, schema, _) do
    {nitems, rest}           = decode_zigzag_varint(data)
    <<type, rest :: binary>> = rest

    # Only ANY is supported by OrientDB at the moment.
    :any = int_to_type(type)

    Enum.map_reduce List.duplicate(nil, nitems), rest, fn(_, <<type, acc :: binary>>) ->
      decode_type(acc, int_to_type(type), schema)
    end
  end

  def decode_type(data, :embedded_set, schema, _) do
    {elems, rest} = decode_type(data, :embedded_list, schema)
    {Enum.into(elems, HashSet.new), rest}
  end

  def decode_type(data, :embedded_map, schema, original_data) do
    {keys, _rest} = decode_map_header(data)
    decode_map_values(original_data, keys, schema)
  end

  def decode_type(data, :link, _, _) do
    {cluster_id, rest} = decode_zigzag_varint(data)
    {position, rest} = decode_zigzag_varint(rest)

    {%RID{cluster_id: cluster_id, position: position}, rest}
  end

  def decode_type(data, :link_list, _, _) do
    {nelems, rest} = decode_zigzag_varint(data)
    {elems, rest} = Enum.map_reduce List.duplicate(nil, nelems), rest, fn(_, acc) ->
      decode_type(acc, :link)
    end

    {{:link_list, elems}, rest}
  end

  def decode_type(data, :link_set, _, _) do
    {{:link_list, elems}, rest} = decode_type(data, :link_list)
    {{:link_set, Enum.into(elems, HashSet.new)}, rest}
  end

  def decode_type(data, :link_map, _, _) do
    {nkeys, rest} = decode_zigzag_varint(data)
    {pairs, rest} = Enum.map_reduce List.duplicate(0, nkeys), rest, fn(_, <<type, acc :: binary>>) ->
      # Only string keys are supported
      :string = int_to_type(type)

      {key, acc} = decode_type(acc, :string)
      {rid, acc} = decode_type(acc, :link)
      {{key, rid}, acc}
    end

    {{:link_map, Enum.into(pairs, %{})}, rest}
  end

  def decode_type(data, :decimal, _, _) do
    <<scale :: 32, value_size :: 32, rest :: binary>>         = data
    <<value :: big-size(value_size)-unit(8), rest :: binary>> = rest

    value = value / round(:math.pow(10, scale))
    {Decimal.new(value), rest}
  end

  # 1 means "embedded" RidBag.
  def decode_type(<<1, size :: 32, rest :: binary>>, :link_bag, _, _) do
    {rids, rest} = Enum.map_reduce List.duplicate(0, size), rest, fn(_, acc) ->
      <<cluster_id :: 16, position :: 64, acc :: binary>> = acc
      {%RID{cluster_id: cluster_id, position: position}, acc}
    end

    {{:link_bag, rids}, rest}
  end

  def decode_type(<<0, _ :: binary>>, :link_bag, _, _) do
    raise MarcoPolo.Error, """
    Tree-based RidBags are not supported by MarcoPolo (yet); only embedded
    RidBags are. You can change your OrientDB server configuration to force
    OrientDB to use embedded RidBags over tree-based ones. To learn more about
    changing the server configuration, visit
    http://orientdb.com/docs/last/Configuration.html.  The setting to change is
    `ridBag.embeddedToSbtreeBonsaiThreshold`: set it to a very high value to
    ensure OrientDB uses embedded RidBags up to that number of relations. For
    example:

        <properties>
          ...
          <entry name="ridBag.embeddedToSbtreeBonsaiThreshold" value="1000000000" />
        </properties>

    Note that for this configuration to take effect for a database, that
    database must be created after this configuration is set on the server.
    """
  end

  defp decode_map_header(data) do
    {nkeys, rest} = decode_zigzag_varint(data)

    Enum.map_reduce List.duplicate(nil, nkeys), rest, fn(_, <<string_type, acc :: binary>>) ->
      # For now, OrientDB only supports STRING keys.
      :string = int_to_type(string_type)

      {key, acc} = decode_type(acc, :string)
      {ptr, acc} = decode_data_ptr(acc)
      <<type, acc :: binary>> = acc

      {field(name: key, type: int_to_type(type), ptr: ptr), acc}
    end
  end

  defp decode_map_values(data, keys, schema) do
    values = Enum.map(keys, &decode_field(data, &1, schema))

    rest =
      case List.last(values) do
        {_, rest} -> rest
        _         -> data
      end

    values =
      values
      |> Enum.map(fn {name_and_value, _rest} -> name_and_value end)
      |> Enum.into(%{})

    {values, rest}
  end

  defp encode_fields(fields, offset) when is_map(fields) do
    offset = offset + header_offset(fields)

    acc = {[], [], offset}
    {fields, values, _} = Enum.reduce fields, acc, fn({field_name, field_value}, {fs, vs, index}) ->
      encoded_value =
        if is_nil(field_value) do
          <<>>
        else
          encode_value(field_value, index)
        end

      encoded_field = encode_field_for_header(field_name, index, field_value)
      index         = index + IO.iodata_length(encoded_value)

      {[encoded_field|fs], [encoded_value|vs], index}
    end

    [Enum.reverse(fields), 0, Enum.reverse(values)]
  end

  defp header_offset(fields) do
    # The last +1 is for the `0` that signals the end of the header.
    fields
    |> Stream.map(fn({name, value}) -> encode_field_for_header(name, 0, value) end)
    |> Stream.map(&IO.iodata_length/1)
    |> Enum.sum
    |> +(1)
  end

  defp encode_embedded(%Document{class: class, fields: fields}, offset) do
    if is_nil(class) do
      class = ""
    end

    encoded_class  = encode_value(class)
    encoded_fields = encode_fields(fields, offset + IO.iodata_length(encoded_class))

    [encoded_class, encoded_fields]
  end

  defp encode_field_for_header(name, ptr, value) do
    type = infer_type(value)
    name = to_string(name)

    if is_nil(value) do
      ptr = 0
      type = :boolean
    end

    [encode_value(name), <<ptr :: 32-signed>>, type_to_int(type)]
  end

  # Encodes a value inferring its type.
  # Made public for testing.
  @doc false
  def encode_value(value, offset \\ 0)

  def encode_value({type, value}, offset),
    do: encode_type(value, type, offset)
  def encode_value(value, offset),
    do: encode_type(value, infer_type(value), offset)

  defp encode_type(value, type, offset)

  defp encode_type(true, :boolean, _offset),  do: <<1>>
  defp encode_type(false, :boolean, _offset), do: <<0>>

  defp encode_type(binary, type, _offset) when type in [:string, :binary] do
    [encode_zigzag_varint(byte_size(binary)), binary]
  end

  defp encode_type(i, type, _offset) when type in [:short, :int, :long] do
    encode_zigzag_varint(i)
  end

  defp encode_type(x, :float, _offset), do: <<x :: 32-float>>
  defp encode_type(x, :double, _offset), do: <<x :: 64-float>>

  defp encode_type(date, :date, _offset) do
     import :calendar, only: [date_to_gregorian_days: 3]
     days = date_to_gregorian_days(date.year, date.month, date.day) - date_to_gregorian_days(1970, 1, 1)
     encode_zigzag_varint(days)
  end

  defp encode_type(dt, :datetime, _offset) do
    datetime = {{dt.year, dt.month, dt.day}, {dt.hour, dt.min, dt.sec}}
    secs     = :calendar.datetime_to_gregorian_seconds(datetime)
    epoch    = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

    encode_type((secs - epoch) * 1000 + dt.msec, :long, 0)
  end

  defp encode_type(record, :embedded, offset) do
    encode_embedded(record, offset)
  end

  defp encode_type(list, :embedded_list, offset) do
    elems = Enum.map list, fn(el) ->
      [type_to_int(infer_type(el)), encode_value(el, offset)]
    end

    [encode_zigzag_varint(length(list)), type_to_int(:any), elems]
  end

  defp encode_type(set, :embedded_set, offset) do
    encode_type(Set.to_list(set), :embedded_list, offset)
  end

  defp encode_type(map, :embedded_map, offset) when is_map(map) do
    offset = offset + map_header_offset(map)

    {keys, values, _} = Enum.reduce map, {[], [], offset}, fn({key, value}, {ks, vs, index}) ->
      encoded_value = <<>>

      if is_nil(value) do
        key = [type_to_int(:string),
               encode_value(to_string(key)),
               <<0 :: 32-signed>>,
               0]
      else
        key = [type_to_int(:string),
               encode_value(to_string(key)),
               <<index :: 32-signed>>,
               type_to_int(infer_type(value))]
        encoded_value = encode_value(value, index)
        index = index + IO.iodata_length(encoded_value)
      end

      {[key|ks], [encoded_value|vs], index}
    end

    keys   = Enum.reverse(keys)
    values = Enum.reverse(values)

    nkeys = map |> map_size |> encode_zigzag_varint

    [nkeys, keys, values]
  end

  defp encode_type(%RID{cluster_id: id, position: pos}, :link, _offset) do
    encode_zigzag_varint(id) <> encode_zigzag_varint(pos)
  end

  defp encode_type(rids, :link_list, offset) do
    [
      encode_zigzag_varint(length(rids)),
      Enum.map(rids, &encode_type(&1, :link, offset))
    ]
  end

  defp encode_type(rids, :link_set, offset) do
    encode_type(Set.to_list(rids), :link_list, offset)
  end

  defp encode_type(rid_map, :link_map, offset) do
    keys_and_values = Enum.map rid_map, fn {k, v} ->
      [type_to_int(:string),
       encode_value(to_string(k), offset),
       encode_value(v, offset)]
    end

    [encode_zigzag_varint(map_size(rid_map)), keys_and_values]
  end

  defp encode_type(rids, :link_bag, _) when is_list(rids) do
    encoded_rids = Enum.map rids, fn(%RID{cluster_id: cluster_id, position: position}) ->
      <<cluster_id :: 16, position :: 64>>
    end

    [1, <<length(rids) :: 32>>|encoded_rids]
  end

  defp map_header_offset(map) do
    keys = Map.keys(map)

    # `6` means 4 bytes for the pointer to the data, 1 byte for the data type,
    # and 1 byte for the key type.
    nkeys       = encode_zigzag_varint(Enum.count(keys))
    key_lengths = Enum.map(keys, &(IO.iodata_length(encode_value(to_string(&1))) + 6))

    byte_size(nkeys) + Enum.sum(key_lengths)
  end

  defp from_pointer_to_end(data, position) when position > 0 do
    binary_part(data, position, byte_size(data) - position)
  end

  defp infer_type(%HashSet{}),               do: :embedded_set
  defp infer_type(%Document{}),              do: :embedded
  defp infer_type(%RID{}),                   do: :link
  defp infer_type(%MarcoPolo.Date{}),        do: :date
  defp infer_type(%MarcoPolo.DateTime{}),    do: :datetime
  defp infer_type(%Decimal{}),               do: :decimal
  defp infer_type(val) when is_boolean(val), do: :boolean
  defp infer_type(val) when is_binary(val),  do: :string
  defp infer_type(val) when is_integer(val), do: :int
  defp infer_type(val) when is_float(val),   do: :double
  defp infer_type(val) when is_list(val),    do: :embedded_list
  defp infer_type(val) when is_map(val),     do: :embedded_map
  defp infer_type(val) when is_nil(val),     do: :boolean # irrelevant
  defp infer_type({type, _}),                do: type

  # http://orientdb.com/docs/last/Types.html
  @types [
    {:boolean, "BOOLEAN", 0},
    {:int, "INTEGER", 1},
    {:short, "SHORT", 2},
    {:long, "LONG", 3},
    {:float, "FLOAT", 4},
    {:double, "DOUBLE", 5},
    {:datetime, "DATETIME", 6},
    {:string, "STRING", 7},
    {:binary, "BINARY", 8},
    {:embedded, "EMBEDDED", 9},
    {:embedded_list, "EMBEDDEDLIST", 10},
    {:embedded_set, "EMBEDDEDSET", 11},
    {:embedded_map, "EMBEDDEDMAP", 12},
    {:link, "LINK", 13},
    {:link_list, "LINKLIST", 14},
    {:link_set, "LINKSET", 15},
    {:link_map, "LINKMAP", 16},
    {:byte, "BYTE", 17},
    {:transient, "TRANSIENT", 18},
    {:date, "DATE", 19},
    {:custom, "CUSTOM", 20},
    {:decimal, "DECIMAL", 21},
    {:link_bag, "LINKBAG", 22},
    {:any, "ANY", 23},
  ]

  for {type_name, stringified_type, type_id} <- @types do
    defp int_to_type(unquote(type_id)),             do: unquote(type_name)
    defp type_to_int(unquote(type_name)),           do: unquote(type_id)
    defp string_to_type(unquote(stringified_type)), do: unquote(type_name)
  end
end
