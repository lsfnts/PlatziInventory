using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Linq;
using System.Threading.Tasks;

namespace Entities
{
    public class StorageEntity
    {
        [Key]
        public string StorageId { get; set; }

        [Required]
        public DateTime LastUpdate { get; set; }

        [Required]
        public int PartialQuantity { get; set; }

        public string ProductId { get; set; }
        public ProductEntity Product {get; set;}

        public string WarehouseId { get; set; }
        public WarehouseEntity Warehouse { get; set; }

        public ICollection<InOutEntity> InOuts { get; set; }
    }
}