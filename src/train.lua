 --[[ Training, adapted from https://github.com/harvardnlp/seq2seq-attn/blob/master/train.lua
--]]
require 'nn'
require 'nngraph'
require 'hdf5'
require 'cudnn'
require 'optim'
require 'paths'

package.path = package.path .. ';src/?.lua' .. ';src/data/?.lua' .. ';src/utils/?.lua' .. ';src/model/?.lua'
require 'model'
require 'data_gen'
require 'logging'

cmd = torch.CmdLine()

-- Input and Output
cmd:text('')
cmd:text('**Input and Output**')
cmd:text('')
cmd:option('-data_base_dir', '/mnt/90kDICT32px', [[The base directory of the image path in data-path. If the image path in data-path is absolute path, set it to /]])
cmd:option('-data_path', '/mnt/val_shuffled_words.txt', [[The path containing data file names and labels. Format per line: image_path characters]])
cmd:option('-val_data_path', '/mnt/val_shuffled_words.txt', [[The path containing validate data file names and labels. Format per line: image_path characters]])
cmd:option('-model_dir', 'train', [[The directory for saving and loading model parameters (structure is not stored)]])
cmd:option('-log_path', 'log.txt', [[The path to put log]])
cmd:option('-output_dir', 'results', [[The path to put visualization results if visualize is set to True]])
cmd:option('-steps_per_checkpoint', 4, [[Checkpointing (print perplexity, save model) per how many steps]])

-- Optimization
cmd:text('')
cmd:text('**Optimization**')
cmd:text('')
cmd:option('-num_epochs', 1000, [[The number of whole data passes]])
cmd:option('-batch_size', 64, [[Batch size]])
cmd:option('-initial_learning_rate', 0.001, [[Initial learning rate, note the we use AdaDelta, so the initial value doe not matter much]])

-- Network
cmd:option('-dropout', 0.3, [[Dropout probability]])
cmd:option('-target_embedding_size', 20, [[Embedding dimension for each target]])
cmd:option('-input_feed', false, [[Whether or not use LSTM attention decoder cell]])
cmd:option('-encoder_num_hidden', 512, [[Number of hidden units in encoder cell]])
cmd:option('-encoder_num_layers', 2, [[Number of hidden layers in encoder cell]])
cmd:option('-decoder_num_layers', 3, [[Number of hidden units in decoder cell]])
cmd:option('-target_vocab_size', 26+10+3, [[Target vocabulary size. Default is = 26+10+3 # 0: PADDING, 1: GO, 2: EOS, >2: 0-9, a-z]])

-- Other
cmd:option('-phase', 'test', [[train or test]])
cmd:option('-gpu_id', 3, [[Which gpu to use. <=0 means use CPU]])
cmd:option('-load_model', false, [[Load model from model-dir or not]])
cmd:option('-seed', 910820, [[Load model from model-dir or not]])
cmd:option('-max_decoder_l', 30, [[Maximum number of output targets]])
cmd:option('-max_encoder_l', 50, [[Maximum length of input feature sequence]])

opt = cmd:parse(arg)
torch.manualSeed(opt.seed)

function train(model, phase, batch_size, num_epochs, train_data, val_data, model_dir, steps_per_checkpoint)
    local loss = 0
    local num_seen = 0
    for epoch = 1, num_epochs do
        train_data:shuffle()
        local forward_only
        if phase == 'train' then
            forward_only = false
        elseif phase == 'test' then
            forward_only = true
        else
            assert(false, 'phase must be either train or test')
        end
        while true do
            train_batch = train_data:nextBatch(batch_size)
            if train_batch == nil then
                break
            end
            loss = loss + model:step(train_batch, forward_only)
            num_seen = num_seen + 1
            --print (loss/num_seen)
            model.global_step = model.global_step + 1
            if model.global_step % steps_per_checkpoint == 0 then
                logging:info(string.format('Step %d - train loss = %f', model.global_step, loss/num_seen))
                if phase == 'train' then
                    logging:info('Saving model')
                    local model_path = paths.concat(model_dir, string.format('model-%d', model.global_step))
                    model:save(model_path)
                    logging:info(string.format('Model saved to %s', model_path))
                    local final_model_path_tmp = paths.concat(model_dir, '.final-model.tmp')
                    local final_model_path = paths.concat(model_dir, 'final-model')
                    os.execute(string.format('cp %s %s', model_path, final_model_path_tmp))
                    os.execute(string.format('mv %s %s', final_model_path_tmp, final_model_path))
                end
                num_seen = 0
                loss = 0
            end
        end
    end

end
function main()
    -- Parse command line 
    opt = cmd:parse(arg)

    logging = logger(opt.log_path)

    local phase= opt.phase
    local batch_size = opt.batch_size
    local num_epochs = opt.num_epochs

    local model_dir = opt.model_dir
    local load_model = opt.load_model

    local gpu_id = opt.gpu_id
    local seed = opt.seed

    if gpu_id > 0 then
        logging:info(string.format('Using CUDA on GPU %d', gpu_id))
        require 'cutorch'
        require 'cunn'
        cutorch.setDevice(gpu_id)
        cutorch.manualSeed(seed)
        use_cuda = true
    else
        logging:info(string.format('Using CPU'))
        use_cuda = false
    end

    -- Build model
    logging:info('Building model')
    local model = Model()
    local final_model = paths.concat(model_dir, 'final-model')
    if load_model and paths.filep(final_model) then
        logging:info('Loading model from %s', final_model)
        model:load(final_model, opt)
    else
        logging:info('Creating model with fresh parameters')
        model:create(opt)
    end
    if not paths.dirp(model_dir) then
        paths.mkdir(model_dir)
    end

    -- Load data
    logging:info(string.format('Load training data from %s', opt.data_path))
    local train_data = DataGen(opt.data_base_dir, opt.data_path)
    logging:info(string.format('Load validating data from %s', opt.val_data_path))
    local val_data = DataGen(opt.data_base_dir, opt.val_data_path)

    train(model, phase, batch_size, num_epochs, train_data, val_data)

    logging:shutdown()
end

main()
