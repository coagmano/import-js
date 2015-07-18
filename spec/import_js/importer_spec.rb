require 'spec_helper'
require 'tmpdir'
require 'pathname'

describe 'Importer' do
  before do
    # Setup mocks
    module VIM
      class Window
        def self.current
          MockVimWindow.new
        end
      end
      class Buffer
        def self.current
          @buffer
        end

        def self.current_buffer=(text)
          @buffer = MockVimBuffer.new(text)
        end

        def self.current_buffer
          @buffer
        end
      end

      def self.message(message)
        @last_message = message
      end

      def self.last_message
        @last_message
      end

      def self.last_inputlist
        @last_inputlist
      end

      def self.evaluate(expression)
        if expression =~ /<cword>/
          @current_word
        elsif expression =~ /inputlist/
          @last_inputlist = expression
          @current_selection || 0
        elsif expression =~ /getline/
          @buffer.to_s
        end
      end

      def self.current_word=(word)
        @current_word = word
      end

      def self.current_selection=(index)
        @current_selection = index
      end
    end
  end

  let(:word) { 'foo' }
  let(:text) { 'foo' } # start with a simple buffer
  let(:existing_files) { [] } # start with a simple buffer
  let(:package_json_content) { nil }

  before do
    VIM.current_word = word
    VIM::Buffer.current_buffer = text

    @tmp_dir = Dir.mktmpdir
    allow_any_instance_of(ImportJS::Configuration)
      .to receive(:get).and_call_original
    allow_any_instance_of(ImportJS::Configuration)
      .to receive(:get).with('lookup_paths').and_return([@tmp_dir])

    existing_files.each do |file|
      full_path = File.join(@tmp_dir, file)
      FileUtils.mkdir_p(Pathname.new(full_path).dirname)
      FileUtils.touch(full_path)
    end

    if (package_json_content)
      File.open(File.join(@tmp_dir, 'Foo/package.json'), 'w') do |f|
        f.write(package_json_content.to_json)
      end
    end
  end

  after do
    FileUtils.remove_entry_secure @tmp_dir
  end

  describe '#import' do
    subject do
      ImportJS::Importer.new.import
      VIM::Buffer.current_buffer.to_s
    end

    context 'with a variable name that will not resolve' do
      it 'leaves the buffer unchanged' do
        expect(subject).to eq(text)
      end

      it 'displays a message' do
        subject
        expect(VIM.last_message).to start_with(
          "[import-js]: No js module to import for variable `#{word}`")
      end
    end

    context 'with no word under the cursor' do
      let(:word) { '' }

      it 'leaves the buffer unchanged' do
        expect(subject).to eq(text)
      end

      it 'displays a message' do
        subject
        expect(VIM.last_message).to eq(
          '[import-js]: No variable to import. Place your cursor on a variable, then try again.')
      end
    end

    context 'with a variable name that will resolve' do
      let(:existing_files) { ['bar/foo.js.jsx'] }

      it 'adds an import to the top of the buffer' do
        expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo');

foo
        EOS
      end

      it 'displays a message about the imported module' do
        expect(VIM.last_message).to start_with(
          '[import-js] Imported `bar/foo`')
      end

      context 'when that variable is already imported' do
        let(:text) { <<-EOS.strip }
var foo = require('bar/foo');

foo
        EOS

        it 'leaves the buffer unchanged' do
          expect(subject).to eq(text)
        end
      end

      context 'when the variable resolves to a node.js conventional module' do
        let(:existing_files) { ['Foo/index.js.jsx'] }

        it 'adds an import to the top of the buffer' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('Foo');

foo
          EOS
        end

        it 'displays a message about the imported module' do
          expect(VIM.last_message).to start_with(
            '[import-js] Imported `Foo (main: index.js.jsx)`')
        end

        context 'when that module has a dot in its name' do
          let(:existing_files) { ['Foo.io/index.js.jsx'] }
          let(:word) { 'FooIO' }
          let(:text) { 'FooIO' }

          it 'imports that module with the dot' do
            expect(subject).to eq(<<-EOS.strip)
var FooIO = require('Foo.io');

FooIO
            EOS
          end

        end
      end

      context 'when other imports exist' do
        let(:text) { <<-EOS.strip }
var zoo = require('foo/zoo');
var bar = require('foo/bar');

foo
        EOS

        it 'adds the import and sorts the entire list' do
          expect(subject).to eq(<<-EOS.strip)
var bar = require('foo/bar');
var foo = require('bar/foo');
var zoo = require('foo/zoo');

foo
        EOS
        end
      end

      context 'when there is an unconventional import' do
        let(:text) { <<-EOS.strip }
var zoo = require('foo/zoo');
var tsar = require('foo/bar').tsar;

foo
        EOS

        it 'adds the import and sorts the entire list' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo');
var tsar = require('foo/bar').tsar;
var zoo = require('foo/zoo');

foo
        EOS
        end
      end

      context 'when there is an import with line-breaks' do
        let(:text) { <<-EOS.strip }
var zoo =
  require('foo/zoo');
var tsar = require('foo/bar').tsar;

var foo = { require: b }
        EOS

        it 'adds the import, sorts the entire list and keeps the line-break' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo');
var tsar = require('foo/bar').tsar;
var zoo =
  require('foo/zoo');

var foo = { require: b }
        EOS
        end
      end

      context 'when there is a blank line amongst current imports' do
        let(:text) { <<-EOS.strip }
var zoo = require('foo/zoo');

var bar = require('foo/bar');
foo
        EOS

        it 'adds the import and sorts the entire list' do
          # TODO: We currently search for current imports until we encounter
          # something that's not an import (like a blank line). We might want to
          # do better here and ignore that whitespace. But for now, this is the
          # behavior:
          expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo');
var zoo = require('foo/zoo');

var bar = require('foo/bar');
foo
        EOS
        end
      end

      context 'when multiple files resolve the variable' do
        let(:existing_files) do
          [
            'bar/foo.js.jsx',
            'zoo/foo.js',
            'zoo/goo/Foo/index.js'
          ]
        end

        it 'displays a message about selecting a module' do
          subject
          expect(VIM.last_inputlist).to include(
            "[import-js] Pick js module to import for 'foo'")
        end

        it 'list all possible imports' do
          subject
          expect(VIM.last_inputlist).to include(
            '1: bar/foo')
          expect(VIM.last_inputlist).to include(
            '2: zoo/foo')
          expect(VIM.last_inputlist).to include(
            '3: zoo/goo/Foo (main: index.js)')
        end

        context 'and the user selects' do
          before do
            VIM.current_selection = selection
          end

          context 'the first file' do
            let(:selection) { 1 }

            it 'picks the first one' do
              expect(subject).to eq(<<-eos.strip)
var foo = require('bar/foo');

foo
              eos
            end
          end

          context 'the second file' do
            let(:selection) { 2 }

            it 'picks the second one' do
              expect(subject).to eq(<<-EOS.strip)
var foo = require('zoo/foo');

foo
              EOS
            end
          end

          context 'index 0 (which is the heading)' do
            let(:selection) { 0 }

            it 'picks nothing' do
              expect(subject).to eq(<<-EOS.strip)
foo
              EOS
            end
          end

          context 'an index larger than the list' do
            # Apparently, this can happen when you use `inputlist`
            let(:selection) { 5 }

            it 'picks nothing' do
              expect(subject).to eq(<<-EOS.strip)
foo
              EOS
            end
          end

          context 'an index < 0' do
            # Apparently, this can happen when you use `inputlist`
            let(:selection) { -1 }

            it 'picks nothing' do
              expect(subject).to eq(<<-EOS.strip)
foo
              EOS
            end
          end
        end
      end

      context 'when the same logical file is matched twice' do
        let(:existing_files) do
          [
            'Foo/lib/foo.jsx',
            'Foo/package.json',
            'zoo/foo.js'
          ]
        end

        let(:package_json_content) do
          {
            main: 'lib/foo.jsx'
          }
        end

        it 'lists the version of the file resolved through package.json' do
          subject
          expect(VIM.last_inputlist).to include(
            '1: Foo (main: lib/foo.jsx)')
        end

        it 'does not list the file also resolved through package.json' do
          subject
          expect(VIM.last_inputlist).to_not include(
            'Foo/lib/foo.jsx')
        end
      end
    end

    context 'importing a module with a package.json file' do
      let(:existing_files) { ['Foo/package.json', 'Foo/build/main.js'] }

      context 'when `main` points to a js file' do
        let(:package_json_content) do
          {
            main: 'build/main.js'
          }
        end

        it 'adds an import to the top of the buffer' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('Foo');

foo
          EOS
        end
      end

      context 'when `main` points to index.js in the same folder' do
        let(:existing_files) { ['Foo/package.json', 'Foo/index.js'] }

        let(:package_json_content) do
          {
            main: 'index.js'
          }
        end

        it 'adds an import to the top of the buffer' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('Foo');

foo
          EOS
        end
      end

      context 'when the module is named something.js' do
        let(:existing_files) { ['Foo.js/package.json', 'Foo.js/main.js'] }
        let(:text) { 'FooJS' }
        let(:word) { 'FooJS' }

        before do
          File.open(File.join(@tmp_dir, 'Foo.js/package.json'), 'w') do |f|
            f.write({ main: 'main.js' }.to_json)
          end
        end

        it 'keeps the .js in the import' do
          expect(subject).to eq(<<-EOS.strip)
var FooJS = require('Foo.js');

FooJS
          EOS
        end
      end

      context 'when `main` is missing' do
        let(:package_json_content) { {} }

        it 'does not add an import' do
          expect(subject).to eq(<<-EOS.strip)
foo
          EOS
        end
      end
    end



    describe 'line wrapping' do
      let(:importer) { ImportJS::Importer.new }

      subject do
        importer.import
        VIM::Buffer.current_buffer.to_s
      end

      context "when lines exceed Vim's textwidth" do
        before(:each) do
          allow_any_instance_of(ImportJS::Configuration)
            .to receive(:text_width)
            .and_return(40)
        end

        let(:existing_files) { ['fiz/bar/biz/baz/fiz/buz/boz/foo.js.jsx'] }

        context 'when expandtab is not set' do
          before(:each) do
            allow_any_instance_of(ImportJS::Configuration)
              .to receive(:expand_tab?)
              .and_return(false)
          end

          it 'wraps them and indents with a tab' do
            expect(subject).to eq(<<-EOS.strip)
var foo =
	require('fiz/bar/biz/baz/fiz/buz/boz/foo');

foo
            EOS
          end
        end

        context 'when expandtab is set' do
          before(:each) do
            allow_any_instance_of(ImportJS::Configuration)
              .to receive(:expand_tab?)
              .and_return(true)
          end

          context 'when shiftwidth is set' do
            before(:each) do
              allow_any_instance_of(ImportJS::Configuration)
                .to receive(:shift_width)
                .and_return(3)
            end

            it 'wraps them and indents with shiftwidth spaces' do
              expect(subject).to eq(<<-EOS.strip)
var foo =
   require('fiz/bar/biz/baz/fiz/buz/boz/foo');

foo
              EOS
            end
          end

          context 'when shiftwidth is not set' do
            before(:each) do
              allow_any_instance_of(ImportJS::Configuration)
                .to receive(:shift_width)
                .and_return(nil)
            end

            it 'wraps them and indents with 2 spaces' do
              expect(subject).to eq(<<-EOS.strip)
var foo =
  require('fiz/bar/biz/baz/fiz/buz/boz/foo');

foo
              EOS
            end
          end
        end
      end

      context "when lines do not exceed Vim's textwidth" do
        before(:each) do
          allow(importer).to receive(:text_width).and_return(80)
        end

        let(:existing_files) { ['bar/foo.js.jsx'] }

        it 'does not wrap them' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo');

foo
          EOS
        end
      end
    end

    context 'configuration' do
      before do
        allow_any_instance_of(ImportJS::Configuration)
          .to(receive(:load_config))
          .and_return(configuration)
      end

      context 'with aliases' do
        let(:configuration) do
          {
            'aliases' => { '$' => 'jquery' }
          }
        end
        let(:text) { '$' }
        let(:word) { '$' }

        it 'resolves aliased imports to the aliases' do
          expect(subject).to eq(<<-EOS.strip)
var $ = require('jquery');

$
        EOS
        end
      end

      context 'when keep_file_extensions is true' do
        let(:existing_files) { ['bar/foo.js'] }
        let(:configuration) do
          {
            'keep_file_extensions' => true
          }
        end

        it 'keeps the file ending in the import' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo.js');

foo
          EOS
        end
      end

      context 'with excludes' do
        let(:existing_files) { ['bar/foo/foo.js'] }
        let(:configuration) do
          {
            'excludes' => ['**/foo/**']
          }
        end

        it 'does not add an import' do
          expect(subject).to eq(<<-EOS.strip)
foo
          EOS
        end

        it 'displays a message' do
          subject
          expect(VIM.last_message).to start_with(
            "[import-js]: No js module to import for variable `#{word}`")
        end
      end

      context 'with declaration_keyword' do
        subject do
          ImportJS::Importer.new.import
          VIM::Buffer.current_buffer.to_s
        end

        let(:configuration) do
          {
            'declaration_keyword' => 'const'
          }
        end

        context 'with a variable name that will resolve' do
          let(:existing_files) { ['bar/foo.js.jsx'] }

          it 'adds an import to the top of the buffer using the declaration_keyword' do
            expect(subject).to eq(<<-EOS.strip)
const foo = require('bar/foo');

foo
            EOS
          end

          context 'when that variable is already imported using `var`' do
            let(:text) { <<-EOS.strip }
var foo = require('bar/foo');

foo
            EOS

            it 'changes the `var` to declaration_keyword' do
              expect(subject).to eq(<<-EOS.strip)
const foo = require('bar/foo');

foo
              EOS
            end
          end

          context 'when the import contains a line-break' do
            let(:text) { <<-EOS.strip }
var foo =
  require('bar/foo');

foo
            EOS

            it 'changes the `var` to declaration_keyword and removes the whitespace' do
              expect(subject).to eq(<<-EOS.strip)
const foo = require('bar/foo');

foo
              EOS
            end
          end

          context 'when other imports exist' do
            let(:text) { <<-EOS.strip }
var zoo = require('foo/zoo');
let bar = require('foo/bar');

foo
            EOS

            it 'adds the import and sorts the entire list' do
              expect(subject).to eq(<<-EOS.strip)
const foo = require('bar/foo');
let bar = require('foo/bar');
var zoo = require('foo/zoo');

foo
            EOS
            end
          end
        end
      end
    end
  end

  describe '#import_all' do
    let(:jshint_result) { '' }
    before do
      allow(Open3).to receive(:capture3).and_call_original
      allow(Open3).to receive(:capture3).with(/jshint/, anything)
        .and_return([jshint_result, nil])
    end

    subject do
      ImportJS::Importer.new.import_all
      VIM::Buffer.current_buffer.to_s
    end

    context 'when no undefined variables exist' do
      it 'leaves the buffer unchanged' do
        expect(subject).to eq(text)
      end

      it 'displays a message' do
        subject
        expect(VIM.last_message).to eq(
          '[import-js]: No variables to import'
        )
      end
    end

    context 'when one undefined variable exists' do
      let(:existing_files) { ['bar/foo.js.jsx'] }
      let(:jshint_result) do
        "stdin: line 3, col 11, 'foo' is not defined."
      end

      it 'imports that variable' do
        expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo');

foo
        EOS
      end

      it 'displays a message' do
        subject
        expect(VIM.last_message).to eq(
          '[import-js]: Imported these variables: ["foo"]'
        )
      end

      context 'when jshint returns other issues' do
        let(:jshint_result) do
          "stdin: line 1, col 1, Use the function form of \"use strict\".\n" \
          "stdin: line 3, col 11, 'foo' is not defined."
        end

        it 'still imports the variable' do
          expect(subject).to eq(<<-EOS.strip)
var foo = require('bar/foo');

foo
          EOS
        end
      end
    end

    context 'when multiple undefined variables exist' do
      let(:existing_files) { ['bar/foo.js.jsx', 'bar.js'] }
      let(:text) { 'var a = foo + bar;' }

      let(:jshint_result) do
        "stdin: line 3, col 11, 'foo' is not defined.\n" \
        "stdin: line 3, col 11, 'bar' is not defined."
      end

      it 'imports all variables' do
        expect(subject).to eq(<<-EOS.strip)
var bar = require('bar');
var foo = require('bar/foo');

var a = foo + bar;
        EOS
      end

      it 'displays a message' do
        subject
        expect(VIM.last_message).to eq(
          '[import-js]: Imported these variables: ["foo", "bar"]'
        )
      end
    end

    context 'when the list of undefined variables has duplicates' do
      let(:existing_files) { ['bar/foo.js.jsx', 'bar.js'] }
      let(:text) { 'var a = foo + bar;' }

      let(:jshint_result) do
        "stdin: line 3, col 11, 'foo' is not defined.\n" +
        "stdin: line 3, col 11, 'foo' is not defined.\n" +
        "stdin: line 3, col 11, 'foo' is not defined.\n" +
        "stdin: line 3, col 11, 'bar' is not defined."
      end

      it 'imports all variables' do
        expect(subject).to eq(<<-EOS.strip)
var bar = require('bar');
var foo = require('bar/foo');

var a = foo + bar;
        EOS
      end

      it 'displays a message' do
        subject
        expect(VIM.last_message).to eq(
          '[import-js]: Imported these variables: ["foo", "bar"]'
        )
      end
    end
  end
end