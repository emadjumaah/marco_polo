defmodule MarcoPolo.Protocol.RecordSerialization do
  @moduledoc false

  require Record

  Record.defrecordp :map_key, [:key, :data_type, :data_ptr]
  Record.defrecordp :typed_field, [:value, :type]

  Record.defrecordp :field_def, [:name, :ptr, :type]

  defmodule Field do
    @type t :: %__MODULE__{
      name: binary,
      type: atom,
      pointer_to_data: non_neg_integer,
      value: term,
      encoded_value: iodata,
    }

    defstruct ~w(name type pointer_to_data value encoded_value)a
  end

  @doc """
  Parses a binary-serialized record.
  """
  @spec decode(binary) :: {non_neg_integer, String.t, %{}}
  def decode(data) do
    <<_version, rest :: binary>> = data
    decode_embedded(rest)
  end

  @doc """
  Serializes a record using the binary serialization protocol.

  `class_name` is a string containing the class name of the record being
  encoded. `fields` is a list of `Field` structs.
  """
  def encode(%MarcoPolo.Record{} = record) do
    [0, encode_embedded(record, 1)]
  end

  # Decodes a document (ODocument). This ODocument can be a "top-level" document
  # or an "embedded" type, since the leading serialization version byte is not
  # decoded here (but in `decode/1`).
  defp decode_embedded(data) do
    {class_name, rest}        = decode_type(data, :string)
    {field_definitions, rest} = decode_header(rest)
    {fields, rest}            = decode_fields(rest, field_definitions)

    if class_name == "" do
      class_name = nil
    end

    {%MarcoPolo.Record{class: class_name, fields: fields}, rest}
    # {{class_name, fields}, rest}
  end

  # Decodes an header returning a list of field definitions (which is a list of
  # `%Field{}` structs).
  defp decode_header(data, acc \\ []) do
    {i, rest} = :small_ints.decode_zigzag_varint(data)

    # If `i` is positive, that means the next field definition is a "named
    # field" and `i` is the length of the field's name. If it's negative, it
    # represents the property id of a property. If it's 0, it signals the end of
    # the header segment.
    cond do
      i == 0 ->
        # Remember to return `rest` and not `data` since `rest` doesn't contain
        # the 0 byte that signals the end of the header, while `data` does; we
        # want to ditch that byte.
        {Enum.reverse(acc), rest}
      i < 0 ->
         raise "properties aren't supported yet, only fields with a name and an explicit type"
      i > 0 ->
        {field, rest} = decode_field_definition(:named_field, data)
        decode_header(rest, [field|acc])
    end
  end

  # Decodes the definition of a named field in the header (`data`).
  defp decode_field_definition(:named_field, data) do
    {field_name, rest}            = decode_type(data, :string)
    {data_ptr, rest}              = decode_data_ptr(rest)
    <<data_type, rest :: binary>> = rest

    # field = %Field{name: field_name, type: int_to_type(data_type), pointer_to_data: data_ptr}

    field = field_def(name: field_name, type: int_to_type(data_type), ptr: data_ptr)
    {field, rest}
  end

  # Decodes fields from the body of a serialized document (`data`) and a list of
  # `%Field{}` structs (with no `:value` field, they're definitions). Returns a
  # list of `%Field{}`s and the rest of the given data.
  defp decode_fields(data, field_definitions) do
    {fields, rest} = Enum.map_reduce field_definitions, data, fn(field_def(name: name) = f, acc) ->
      if field_def(f, :ptr) == 0 do
        {{name, nil}, acc}
      else
        {value, rest} = decode_type(acc, field_def(f, :type))
        {{name, value}, rest}
      end
    end

    {Enum.into(fields, %{}), rest}
  end

  # The pointer to the data is just a signed int32.
  defp decode_data_ptr(data) do
    <<data_ptr :: 32-signed, rest :: binary>> = data
    {data_ptr, rest}
  end

  # Decodes an instance of `type` from `data`.
  # Made public for testing.
  @doc false
  def decode_type(data, type)

  def decode_type(<<0>> <> rest, :boolean), do: {false, rest}
  def decode_type(<<1>> <> rest, :boolean), do: {true, rest}

  def decode_type(data, type) when type in [:short, :int, :long] do
    :small_ints.decode_zigzag_varint(data)
  end

  def decode_type(data, :float) do
    <<float :: 32-float, rest :: binary>> = data
    {float, rest}
  end

  def decode_type(data, :double) do
    <<double :: 64-float, rest :: binary>> = data
    {double, rest}
  end

  def decode_type(data, type) when type in [:string, :binary] do
    {len, rest} = :small_ints.decode_zigzag_varint(data)
    <<string :: bytes-size(len), rest :: binary>> = rest
    {string, rest}
  end

  def decode_type(data, :datetime) do
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

  def decode_type(data, :embedded) do
    decode_embedded(data)
  end

  def decode_type(data, :embedded_list) do
    {nitems, rest} = :small_ints.decode_zigzag_varint(data)
    <<type, rest :: binary>> = rest

    # Only ANY is supported by OrientDB at the moment.
    :any = int_to_type(type)

    # OPTIMIZE: I have to find a better (clean) way to `map_reduce` n times
    # instead of mapreducing over a list of n times the number 0, which is
    # uselessly expensive to build and plain useless. A range doesn't work
    # because `Enum.to_list(1..0)` is `[1, 0]` which makes sense, but my
    # 1..nitems has to translate to `[]` so that the mapreducing doesn't
    # actually happen.
    Enum.map_reduce List.duplicate(0, nitems), rest, fn(_, acc) ->
      <<type, acc :: binary>> = acc
      decode_type(acc, int_to_type(type))
    end
  end

  def decode_type(data, :embedded_set) do
    {elems, rest} = decode_type(data, :embedded_list)
    {Enum.into(elems, HashSet.new), rest}
  end

  def decode_type(data, :embedded_map) do
    {keys, rest}   = decode_map_header(data)
    {keys_and_values, rest} = decode_map_values(rest, keys)

    {Enum.into(keys_and_values, %{}), rest}
  end

  def decode_type(<<cluster_id :: 32, position :: 32, rest :: binary>>, :link) do
    {%MarcoPolo.RID{cluster_id: cluster_id, position: position}, rest}
  end

  def decode_type(data, :link_list) do
    {nelems, rest} = :small_ints.decode_zigzag_varint(data)
    {elems, rest} = Enum.map_reduce List.duplicate(0, nelems), rest, fn(_, acc) ->
      decode_type(acc, :link)
    end

    {{:link_list, elems}, rest}
  end

  def decode_type(data, :link_set) do
    {{:link_list, elems}, rest} = decode_type(data, :link_list)
    {{:link_set, Enum.into(elems, HashSet.new)}, rest}
  end

  def decode_type(data, :decimal) do
    <<scale :: 32, value_size :: 32, rest :: binary>> = data
    nbits = value_size * 8
    <<value :: size(nbits)-big, rest :: binary>> = rest

    value = value / round(:math.pow(10, scale))
    {Decimal.new(value), rest}
  end

  defp decode_map_header(data) do
    {nkeys, rest} = :small_ints.decode_zigzag_varint(data)

    Enum.map_reduce List.duplicate(0, nkeys), rest, fn(_, <<string_type, acc :: binary>>) ->
      # For now, OrientDB only supports STRING keys.
      :string = int_to_type(string_type)

      {key, acc} = decode_type(acc, :string)
      {ptr, acc} = decode_data_ptr(acc)
      <<type, acc :: binary>> = acc

      {map_key(key: key, data_type: int_to_type(type), data_ptr: ptr), acc}
    end
  end

  defp decode_map_values(data, keys) do
    Enum.map_reduce keys, data, fn(map_key(key: key_name, data_type: type, data_ptr: ptr), acc) ->
      if ptr == 0 do
        {{key_name, nil}, acc}
      else
        {value, acc} = decode_type(acc, type)
        {{key_name, value}, acc}
      end
    end
  end

  defp encode_fields(%{} = fields, offset) do
    offset = offset + header_offset(fields)

    acc = {[], [], offset}
    {fields, values, _} = Enum.reduce fields, acc, fn({field_name, field_value}, {fs, vs, index}) ->
      encoded_value = encode_value(field_value, index)
      encoded_field = encode_field_for_header(field_name, index, field_value)
      index         = index + IO.iodata_length(encoded_value)

      {[encoded_field|fs], [encoded_value|vs], index}
    end

    [Enum.reverse(fields), 0, Enum.reverse(values)]
  end

  # Returns the length of the header based on the list of fields.
  defp header_offset(fields) do
    # The last +1 is for the `0` that signals the end of the header.
    fields
    |> Stream.map(fn({name, value}) -> encode_field_for_header(name, 0, value) end)
    |> Stream.map(&IO.iodata_length/1)
    |> Enum.sum
    |> +(1)
  end

  defp encode_embedded(%MarcoPolo.Record{class: class, fields: fields}, offset) do
    encoded_class  = encode_value(class, offset)
    encoded_fields = encode_fields(fields, offset + IO.iodata_length(encoded_class))

    [encoded_class, encoded_fields]
  end

  # Encodes the given `%Field{}` for the header, i.e., just the field
  # representation and not the value (name, pointer to data, type). Returns
  # iodata.
  defp encode_field_for_header(name, ptr, value) do
    type = infer_type(value)
    if is_nil(value) do
      ptr = 0
      type = :boolean
    end

    [encode_value(name), <<ptr :: 32-signed>>, type_to_int(type)]
  end

  @doc false
  def encode_value(value, offset \\ 0)

  def encode_value({type, value}, offset) do
    encode_type(value, type, offset)
  end

  def encode_value(value, offset) do
    encode_type(value, infer_type(value), offset)
  end

  defp encode_type(value, type, offset)

  defp encode_type(true, :boolean, _offset),  do: <<1>>
  defp encode_type(false, :boolean, _offset), do: <<0>>

  defp encode_type(binary, type, _offset) when type in [:string, :binary] do
    [:small_ints.encode_zigzag_varint(byte_size(binary)), binary]
  end

  defp encode_type(i, type, _offset) when type in [:short, :int, :long] do
    :small_ints.encode_zigzag_varint(i)
  end

  defp encode_type(x, :float, _offset), do: <<x :: 32-float>>
  defp encode_type(x, :double, _offset), do: <<x :: 64-float>>

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

    [:small_ints.encode_zigzag_varint(length(list)), type_to_int(:any), elems]
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

    nkeys = map |> map_size |> :small_ints.encode_zigzag_varint

    [nkeys, keys, values]
  end

  defp map_header_offset(map) do
    keys = Map.keys(map)

    # `6` means 4 bytes for the pointer to the data, 1 byte for the data type,
    # and 1 byte for the key type.
    nkeys       = :small_ints.encode_zigzag_varint(Enum.count(keys))
    key_lengths = Enum.map(keys, &(IO.iodata_length(encode_value(to_string(&1))) + 6))

    byte_size(nkeys) + Enum.sum(key_lengths)
  end

  defp infer_type(value)

  defp infer_type(%HashSet{}),               do: :embedded_set
  defp infer_type(%MarcoPolo.Record{}),      do: :embedded
  defp infer_type(%MarcoPolo.RID{}),         do: :link
  defp infer_type(%MarcoPolo.DateTime{}),    do: :datetime
  defp infer_type(%Decimal{}),               do: :decimal
  defp infer_type(val) when is_boolean(val), do: :boolean
  defp infer_type(val) when is_binary(val),  do: :string
  defp infer_type(val) when is_integer(val), do: :int
  defp infer_type(val) when is_float(val),   do: :double
  defp infer_type(val) when is_list(val),    do: :embedded_list
  defp infer_type(val) when is_map(val),     do: :embedded_map
  defp infer_type(val) when is_nil(val),     do: :boolean # irrelevant
  defp infer_type({type, _value}), do: type

  # http://orientdb.com/docs/last/Types.html
  @types [
    boolean: 0,
    int: 1,
    short: 2,
    long: 3,
    float: 4,
    double: 5,
    datetime: 6,
    string: 7,
    binary: 8,
    embedded: 9,
    embedded_list: 10,
    embedded_set: 11,
    embedded_map: 12,
    link: 13,
    link_list: 14,
    link_set: 15,
    link_map: 16,
    byte: 17,
    transient: 18,
    date: 19,
    custom: 20,
    decimal: 21,
    link_bag: 22,
    any: 23,
  ]

  for {type_name, type_id} <- @types do
    defp int_to_type(unquote(type_id)), do: unquote(type_name)
    defp type_to_int(unquote(type_name)), do: unquote(type_id)
  end
end
