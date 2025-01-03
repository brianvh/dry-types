# frozen_string_literal: true

RSpec.describe Dry::Types::Schema do
  subject(:schema) do
    Dry::Types["hash"].schema(
      name: "coercible.string",
      age: "integer",
      active: "params.bool"
    )
  end

  it_behaves_like "a constrained type" do
    let(:type) { schema }

    it_behaves_like "a composable constructor"
  end

  describe "#each" do
    it "iterates over keys" do
      expect(schema.each.to_a).to eql(schema.name_key_map.values_at(:name, :age, :active))
    end

    it "makes schema act as Enumerable" do
      expect(schema.map(&:name)).to eql(%i[name age active])
    end

    it "returns enumerator" do
      enumerator = schema.each

      expect(enumerator.next).to be(schema.name_key_map[:name])
    end
  end

  describe "#key?" do
    it "checks key presence" do
      expect(schema.key?(:name)).to be true
      expect(schema.key?(:missing)).to be false
    end
  end

  describe "#constrained?" do
    subject(:type) { Dry::Types["nominal.hash"].schema({}) }

    it "is a contrained type" do
      expect(type).to be_constrained
    end

    context "sum" do
      subject(:sum) { type.strict | type.strict }

      it "produces a constrained sum" do
        expect { sum.(foo: 1) }.to raise_error(Dry::Types::UnknownKeysError)
      end
    end
  end

  describe "#key" do
    it "fetches a key type" do
      expect(schema.key(:name)).to be(schema.name_key_map[:name])
    end

    it "raises a key error if key is unknown" do
      expect { schema.key(:missing) }.to raise_error(KeyError, "key not found: :missing")
    end

    it "accepts a fallback" do
      expect(schema.key(:missing, :fallback)).to eql(:fallback)
    end

    it "accepts a fallback block" do
      expect(schema.key(:missing) { :fallback }).to eql(:fallback)
    end

    it "discards schema constructor" do
      expect(schema.constructor(&:to_hash).key(:name)).to be(schema.name_key_map[:name])
    end

    context "nested schema" do
      let(:name_schema) do
        Dry::Types["hash"].schema(first_name: "string", last_name: "string")
      end

      subject(:schema) do
        Dry::Types["hash"].schema(name: name_schema)
      end

      it "still discards constructor" do
        expect(schema.constructor(&:to_hash).key(:name).type).to eql(name_schema)
      end
    end
  end

  describe "#call" do
    let(:type) { Dry::Types["nominal.hash"].schema({}).strict }

    it "takes a block for fallback case" do
      expect(type.(extra_key: :invalid) { "fallback" }).to eql("fallback")
    end
  end

  describe "omittable keys" do
    subject(:schema) do
      Dry::Types["strict.hash"].schema(
        age: Dry::Types["strict.integer"].meta(omittable: true)
      )
    end

    example "keys can be set as not required via meta" do
      expect(schema.({})).to eql({})
    end
  end

  describe "hash schema" do
    subject(:type) { Dry::Types["nominal.hash"] }

    let(:phone_struct) do
      Struct.new(:prefix, :number) do
        def self.name
          "Phone"
        end

        def self.to_ary
          [prefix, number]
        end
      end
    end

    before do
      PhoneType = Dry::Types::Nominal.new(phone_struct).constructor(-> args { phone_struct.new(*args) })
    end

    after do
      Object.send(:remove_const, :PhoneType)
    end

    let(:hash_schema) do
      {
        name: "coercible.string",
        age: "strict.integer",
        active: "params.bool",
        phone: PhoneType
      }
    end

    let(:primitive) do
      type.meta(my: :metadata)
    end

    subject(:hash) { primitive.schema(hash_schema) }

    let(:valid_input) { {name: "John", age: 23, active: true, phone: phone_struct.new(1, 23)} }

    let(:phone) { PhoneType.primitive }

    it_behaves_like Dry::Types::Nominal do
      let(:type) { Dry::Types["nominal.hash"].schema(hash_schema) }

      it_behaves_like "a composable constructor"
    end

    it_behaves_like "Dry::Types::Nominal#meta" do
      let(:type) { Dry::Types["nominal.hash"].schema(hash_schema) }

      it_behaves_like "a composable constructor"
    end

    context "members with default values" do
      let(:hash) do
        primitive.schema({
                           **hash_schema,
                           age: Dry::Types["strict.integer"].default(21)
                         })
      end

      it "resolves missing keys with default values" do
        params = {name: "Jane", active: true, phone: []}
        expect(hash[params][:age]).to eql(21)
      end
    end

    it "preserves metadata" do
      expect(hash.meta[:my]).to eql(:metadata)
    end

    it "has a Hash primitive" do
      expect(hash.primitive).to be(Hash)
    end

    it "is callable via #[]" do
      params = {name: :Jane, age: 21, active: true, phone: []}
      expect(hash[params]).to eql(hash.call(params))
    end

    it "builds hash using provided schema" do
      user_hash = hash.call(
        name: :Jane, age: 21, active: true,
        phone: ["+48", "123-456-789"]
      )

      expect(user_hash).to eql(
        name: "Jane", age: 21, active: true,
        phone: phone.new("+48", "123-456-789")
      )
    end

    it "applies member types" do
      input = {name: :John, age: 21, active: "true", phone: %w[1 234]}
      result = hash.try(input)

      expect(result).to be_success
      expect(result.input).to eql(name: "John", age: 21, active: true, phone: phone.new("1", "234"))
    end

    it "keeps original values when applying a member type fails" do
      input = {age: "twenty one", active: "0", name: "John", phone: %w[1 234]}
      result = hash.try(input)

      expect(result).to be_failure
      expect(result.input).to eql(age: "twenty one", active: false, name: "John", phone: phone.new("1", "234"))
    end

    it "yields failure on #try when applying a member type fails" do
      input = {age: "twenty one", active: "0", name: "John", phone: %w[1 234]}

      # assert that a failed #try yields a failure result
      expect { |rspec_probe|
        hash.try(input, &rspec_probe)
      }.to yield_with_args(instance_of(Dry::Types::Result::Failure))

      # assert that the failure result provides context for the failing input
      hash.try(input) do |failure|
        expect(failure.error.meta[:age].success?).to be(false)
      end
    end

    it "returns failure on #try when a member is missing" do
      input = {active: "0", name: "John", phone: %w[1 234]}

      result = hash.try(input)

      expect(result).to be_failure
    end

    describe "#valid?" do
      it "returns boolean" do
        expect(hash.valid?(name: "John", age: 23, active: 1, phone: 1)).to eql(true)
        expect(hash.valid?(name: "John", age: "23", active: 1, phone: 1)).to eql(false)
      end
    end

    describe "#===" do
      it "returns boolean" do
        expect(hash.===(name: "John", age: 23, active: 1, phone: 1)).to eql(true)
        expect(hash.===(name: "John", age: "23", active: 1, phone: 1)).to eql(false)
      end
    end

    it "raises MissingKeyError if input is missing a key" do
      expect {
        hash.call(name: :Jane, active: true, phone: ["+48", "123-456-789"])
      }.to raise_error(
        Dry::Types::MissingKeyError, /:age is missing in Hash input/
      )
    end

    it "fails if any coercions are unsuccessful" do
      expect {
        hash.call(name: :Jane, age: "oops", active: true, phone: [])
      }.to raise_error(
        an_instance_of(Dry::Types::SchemaError).and(
          having_attributes(
            message: '"oops" (String) has invalid type for :age violates ' \
                     'constraints (type?(Integer, "oops") failed)',
            key: :age,
            value: "oops"
          )
        )
      )
    end

    it "provides a key for type errors" do
      expect {
        hash.schema(age: "coercible.integer").call(name: :Jane, age: nil, active: true, phone: [])
      }.to raise_error(
        an_instance_of(Dry::Types::SchemaError).and(
          having_attributes(
            message: "nil (NilClass) has invalid type for :age violates constraints " \
                     "(can't convert nil into Integer failed)",
            key: :age,
            value: nil
          )
        )
      )
    end

    it "provides a key for argument errors" do
      expect {
        hash.schema(age: "coercible.integer").call(name: :Jane, age: "oops", active: true, phone: [])
      }.to raise_error(
        an_instance_of(Dry::Types::SchemaError).and(
          having_attributes(
            message: '"oops" (String) has invalid type for :age violates constraints ' \
                     '(invalid value for Integer(): "oops" failed)',
            key: :age,
            value: "oops"
          )
        )
      )
    end

    it "ignores unexpected keys" do
      expect(subject.({**valid_input, not: :expect})).not_to have_key(:not)
    end

    it "uses type even if it is a class with a registered name" do
      bool = Class.new do
        extend Dry::Types::Type

        def self.meta
          {}
        end
      end
      stub_const("Bool", bool)
      expect(hash.schema(bool: bool).key(:bool).type).to be(bool)
    end

    describe "#strict" do
      subject { hash.strict }

      it "makes the schema strict" do
        expected_input = {name: :Jane, age: 21, active: true, phone: %w[1 2]}
        unexpected_input = {gender: "F", email: "Jane@hotmail.biz"}

        expect {
          subject.(expected_input.merge(unexpected_input))
        }.to raise_error(Dry::Types::UnknownKeysError)
          .with_message("unexpected keys [:gender, :email] in Hash input")
      end

      it "can make a strict schema not strict again" do
        expect(subject.strict(false)).not_to be_strict
      end
    end

    describe "#strict?" do
      example do
        expect(subject).not_to be_strict
        expect(subject.strict).to be_strict
      end
    end

    describe "#with_key_transform" do
      it "adds a key transformation" do
        schema = subject.with_key_transform { |k| k.downcase.to_sym }
        expect(
          schema.("NAME" => "John", "AGE" => 23, "ACTIVE" => true, "PHONE" => [1, 23])
        ).to eql(valid_input)
      end

      it "accepts a proc" do
        schema = subject.with_key_transform(-> k { k.downcase.to_sym })
        expect(
          schema.("NAME" => "John", "AGE" => 23, "ACTIVE" => true, "PHONE" => [1, 23])
        ).to eql(valid_input)
      end

      it "raises an error on missing fn" do
        expect { subject.with_key_transform }.to raise_error(ArgumentError)
      end
    end

    describe "optional keys" do
      let(:hash_schema) do
        {
          name: "coercible.string",
          age: "strict.integer",
          active: "params.bool",
          phone: PhoneType.meta(required: false)
        }
      end

      it "allows to skip certain keys" do
        expect(
          subject.(name: :Jane, age: 21, active: "1")
        ).to eql(name: "Jane", age: 21, active: true)
      end
    end

    describe "#schema" do
      it "extends existing schema" do
        extended = subject.schema(city: "coercible.string")
        expect(extended.({**valid_input, city: :London})).to include(city: "London")
        expect(extended.key(:city).type).to eql(Dry::Types["coercible.string"])
      end

      example "in presence of type transformation" do
        extended = subject.with_type_transform { |k| k.meta(transformed: true) }.schema(city: "coercible.string")
        expect(extended.({**valid_input, city: :London})).to include(city: "London")
        string = Dry::Types["coercible.string"].meta(transformed: true)
        expect(extended.key(:city)).to eql(Dry::Types::Schema::Key.new(string, :city))
      end

      it "accepts only symbol keys" do
        ["string_key", 42, Object.new, {}, []].each do |invalid_key|
          expect {
            hash.schema(valid: "symbol", invalid_key => "integer")
          }.to raise_error(
            ArgumentError, /Schemas can only contain symbol keys/
          )
        end
      end
    end

    describe "keys ending with question mark" do
      let(:hash_schema) do
        {name: "coercible.string", age?: "strict.integer"}
      end

      example "not required" do
        expect(subject.key(:age)).not_to be_required
      end
    end
  end

  describe "#to_s" do
    context "empty schema" do
      subject(:type) { Dry::Types["nominal.hash"].schema({}) }

      it "returns string representation of the type" do
        expect(type.to_s).to eql("#<Dry::Types[Schema<keys={}>]>")
      end
    end

    context "strict schema" do
      subject(:type) { Dry::Types["nominal.hash"].schema({}).strict }

      it "returns string representation of the type" do
        expect(type.to_s).to eql("#<Dry::Types[Schema<strict keys={}>]>")
      end
    end

    context "key transformation" do
      let(:key_transformation) { :to_sym.to_proc }

      subject(:type) { Dry::Types["nominal.hash"].schema({}).with_key_transform(key_transformation) }

      it "returns string representation of the type" do
        expect(type.to_s).to eql("#<Dry::Types[Schema<key_fn=.to_sym keys={}>]>")
      end
    end

    context "type transformation" do
      let(:type_transformation) { :lax.to_proc }

      subject(:type) { Dry::Types["nominal.hash"].with_type_transform(type_transformation).schema({}) }

      it "returns string representation of the type" do
        expect(type.to_s).to eql("#<Dry::Types[Schema<type_fn=.lax keys={}>]>")
      end
    end

    context "schema with keys" do
      subject(:type) do
        Dry::Types["nominal.hash"].schema(
          name: "nominal.string",
          age?: "nominal.integer"
        )
      end

      it "returns string representation of the type" do
        expect(type.to_s).to eql(
          "#<Dry::Types[Schema<keys={name: Nominal<String> age?: Nominal<Integer>}>]>"
        )
      end
    end

    context "strict schema with keys" do
      subject(:type) { Dry::Types["strict.hash"].schema(age: "strict.integer") }

      it "returns string representation of the type" do
        expect(type.to_s).to eql(
          "#<Dry::Types[Constrained<Schema<" \
          "keys={age: Constrained<Nominal<Integer> rule=[type?(Integer)]>" \
          "}> rule=[type?(Hash)]>]>"
        )
      end
    end
  end

  describe "#apply" do
    context "ignoring missing keys" do
      subject(:type) do
        Dry::Types["nominal.hash"].schema(
          name: "coercible.string",
          age: "coercible.integer",
          city: Dry::Types["strict.string"].default("New York")
        )
      end

      it "can be partially applied" do
        expect(type.apply({age: "18"}, skip_missing: true)).to eql(age: 18, city: "New York")
      end

      it "can skip resolving default values" do
        expect(
          type.apply({age: "18"}, skip_missing: true, resolve_defaults: false)
        ).to eql(age: 18)
      end
    end
  end

  describe "#transform_keys?" do
    let(:schema) { Dry::Types["hash"].schema(name: "string") }

    context "without key transformation" do
      subject(:type) { schema }

      specify { expect(type.transform_keys?).to be(false) }
    end

    context "with key transformation" do
      subject(:type) { schema.with_key_transform(:to_sym.to_proc) }

      specify { expect(type.transform_keys?).to be(true) }
    end
  end

  describe "#merge" do
    it "adds keys and values from given schema" do
      schema1 = Dry::Types["hash"].schema(name: "string")
      schema2 = Dry::Types["hash"].schema(age: "integer")

      schema = schema1.merge(schema2)

      expect(schema.keys.map(&:name)).to eq([:name, :age])
    end

    it "gives preference to given struct" do
      schema1 = Dry::Types["hash"].schema(foo: "string")
      schema2 = Dry::Types["hash"].schema(foo: "integer")

      schema = schema1.merge(schema2)

      expect(schema[foo: 1]).to eq(foo: 1)
    end

    it "keeps type transformations from both schemas" do
      transf1 = ->(key) { key.constructor { "Transf 1" } }
      transf2 = ->(key) { key.constructor { "Transf 2" } }
      schema1 = Dry::Types["hash"].with_type_transform(transf1).schema(foo: "string")
      schema2 = Dry::Types["hash"].with_type_transform(transf2).schema(bar: "string")

      schema = schema1.merge(schema2)

      expect(schema[foo: "foo", bar: "bar"]).to eq(foo: "Transf 1", bar: "Transf 2")
    end

    it "preserves key transformations from the caller schema" do
      schema1 = Dry::Types["hash"].schema(foo: "string").with_key_transform(&:to_sym)
      transf2 = ->(key) { :"#{key}_" }
      schema2 = Dry::Types["hash"].schema(bar: "string").with_key_transform(transf2)

      schema = schema1.merge(schema2)

      expect(schema["foo" => "foo", "bar" => "bar"]).to eq(foo: "foo", bar: "bar")
    end
  end

  describe "#clear" do
    it "simply removes all keys" do
      expect(Dry::Types["hash"].schema(foo: "string").clear).to eql(Dry::Types["hash"].schema({}))
    end
  end
end
